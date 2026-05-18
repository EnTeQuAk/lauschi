"""4-eye verification: second AI model verifies curation decisions.

Reads a curated+reviewed JSON and asks a different model to independently
verify. Auto-approves when both models agree, escalates disagreements
for human review.

Pipeline: curated → ai_reviewed → ai_verified → approved/escalated
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

import click
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext, ToolOutput
from lauschi_catalog._opencode import build_mistral_model, build_opencode_model
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.catalog.lifecycle import review_is_stale, verification_is_stale
from lauschi_catalog.catalog.loader import load_raw, save_raw, SERIES_YAML
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.retry import is_retryable

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_VERIFY_MODEL = "minimax-m2.7"
_MAX_RETRIES = 3
_RETRY_DELAY = 5


# ── Output models ──────────────────────────────────────────────────────────

class OverrideVerdict(BaseModel):
    album_id: str
    agree: bool
    reason: str = ""


class SplitVerdict(BaseModel):
    new_id: str
    agree: bool
    reason: str = ""


class FactVerdict(BaseModel):
    """Verify's opinion on a specific proposed fact."""

    fact_type: Literal["era_boundary", "known_gap", "sub_series"]
    identifier: str | int  # label for era_boundary/sub_series, number for known_gap
    agree: bool
    reason: str = ""


class VerifyResult(BaseModel):
    series_id: str
    approve: bool = Field(
        description="True if the curation is correct overall. "
        "False if issues need human attention. "
        "Fact disagreements alone do NOT set this to False; use "
        "fact_verdicts for those. Only set False when facts contradict "
        "decisions in ways that would corrupt the catalog.",
    )
    override_verdicts: list[OverrideVerdict] = Field(default_factory=list)
    split_verdicts: list[SplitVerdict] = Field(default_factory=list)
    fact_verdicts: list[FactVerdict] = Field(default_factory=list)
    concerns: str = Field(
        default="",
        description="Issues found, even if still approving.",
    )


# ── Agent ──────────────────────────────────────────────────────────────────

@dataclass
class Deps:
    providers: list[CatalogProvider]
    series_id: str
    curation: dict
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _MAX_SEARCHES: int = 3
    _MAX_FETCHES: int = 2


_SYSTEM_PROMPT = """\
You are the second reviewer in a 4-eye verification process for "lauschi",
a DACH children's audio player catalog.

A first AI has already curated this series (decided which albums from Spotify
and Apple Music to include/exclude) and reviewed its own work. Your job is
to independently verify those decisions.

## What you're checking

1. **Included albums**: Do these look like real episodes of this series?
   Albums may come from different providers (Spotify, Apple Music). The same
   episode on both providers is fine and expected — different provider
   metadata (titles, release dates, track counts) does NOT make it a
   duplicate. Worked example: spotify "01/Majas Geburt" (1977, 26 tracks)
   and apple_music "Klassiker, Folge 1: Maja lernt fliegen" (1976, 3 tracks)
   are the SAME episode, different catalogs. BOTH should be included.

2. **Excluded albums**: Were these correctly excluded? Real episodes should
   not be excluded. Valid exclusions: compilations, box sets, best-of,
   soundtracks, Lieder albums, karaoke, unrelated content.

3. **Overrides** (changes the first AI proposed): Do you agree with each?

4. **Splits** (proposed sub-series): Do these make sense?

5. **Facts** (era boundaries, known gaps, sub-series): Does the prompt
   show any series_facts? Check whether they match the album data.
   - era_boundaries: Do release dates cluster as described?
   - known_gaps: Is the stated reason plausible (legal dispute, skipped
     number)? Or is it a curation error (episode actually exists)?
   - sub_series: Do the claimed albums really belong to a separate series?
   Record your opinion using `fact_verdicts`. For each fact, set:
   - `fact_type`: exactly one of `era_boundary`, `known_gap`, `sub_series`
   - `identifier`: the era label (string) or gap number (int)
   - `agree`: true if the fact matches the album data, false otherwise
   Disagreeing with a fact does NOT set `approve: false` — only flag the
   fact. Set `approve: false` only when facts contradict album decisions.

## Your decision

- `approve: true` if sound overall. Minor issues OK.
- `approve: false` if significant problems: real episodes excluded, wrong
  content included, bad splits.
- Fill `concerns` with any issues, even if approving.
- For each override and split, state whether you agree.

## Confidence budget

Spend your reasoning budget proportionally to confidence signals.
HIGH-confidence decisions are unlikely to be where the curator went wrong;
sample them lightly. MEDIUM and LOW confidence decisions warrant per-item
review — check the `notes` field and form an independent verdict. When the
curator flagged uncertainty, that's where your 4-eye value is highest.

## Tools

- **web_search**: Search the web for series info. Max 3 searches.
  Use this when uncertain about a series (is it a Hörspiel? how many
  episodes exist? is this the right artist?). Good queries:
  - `"Series Name" Hörspiel Episodenliste` for episode counts
  - `site:hoerspiele.de "Series Name"` for the authoritative German
    Hörspiel database (has episode numbers, titles, publishers)
  - `"Series Name" Hörspiel OR Hörbuch` to clarify format
- **fetch_page**: Fetch a URL from search results for details. Max 2 fetches.
  Useful for hoerspiele.de series pages that list all episodes.
- **album_details**: Check album track listings. Max 5 IDs.

## Rules

- Do NOT propose new overrides or splits. Only verify existing ones.
- Use web_search when: 0 albums included, all albums excluded,
  you're unsure whether something is a Hörspiel or Hörbuch, or the
  artist ID looks wrong for the series.
- **When in doubt, escalate.** lauschi is a kids' audio catalog —
  the cost of approving wrong content (an inappropriate album reaching
  a child) is much higher than the cost of escalating a borderline
  case for human review. Set ``approve: false`` whenever you're not
  confident the curation is correct.

## Tool limits (hard caps)

Some tools have per-run caps. When a tool responds with "limit
reached", do NOT call that tool again — use what you already have
and move on. This is normal, not an error.

- ``web_search``: max 3 calls
- ``fetch_page``: max 2 calls
- ``album_details``: max 5 calls

If a tool returns an error about args or missing data, fix the
args and retry. If it returns "limit reached", stop calling it.
"""


def _build_verify_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, VerifyResult]:
    model = (
        build_mistral_model(model_name, api_key)
        if model_name.startswith("mistral-")
        else build_opencode_model(model_name, api_key)
    )
    # Wrap in ToolOutput so the model emits VerifyResult as a function-call
    # payload rather than free-form JSON in message content. Same mechanism
    # review.py uses; gives stronger schema adherence on models that
    # otherwise occasionally return malformed structured output.
    agent: Agent[Deps, VerifyResult] = Agent(
        model,
        output_type=ToolOutput(
            VerifyResult,
            name="submit_verdict",
            description=(
                "Submit your verification verdict. Use override_verdicts "
                "and split_verdicts to record per-item agreement; concerns "
                "for any issues worth flagging even when approving."
            ),
        ),
        system_prompt=_SYSTEM_PROMPT,
        tool_retries=2, output_retries=2,
    )

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], provider_name: str, album_ids: list[str],
    ) -> list[dict]:
        """Get detailed album info from a specific provider. Max 5 IDs.

        Returns per album: ``{id, name, provider, release_date,
        total_tracks, label, artists, tracks (first 10 names)}``.
        ``release_date`` (ISO YYYY-MM-DD or YYYY) and ``artists``
        come free with the same fetch — use them to verify
        original-vs-reissue and wrong-artist concerns the first
        reviewer might have missed.
        """
        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return [{"error": f"Provider {provider_name} not available"}]
        results = []
        for aid in album_ids[:5]:
            album = target.album_details(aid)
            if album:
                results.append({
                    "id": album.id, "name": album.name, "provider": provider_name,
                    "release_date": album.release_date,
                    "total_tracks": album.total_tracks,
                    "label": album.label,
                    "artists": album.artists,
                    "tracks": [{"name": t.name} for t in album.tracks[:10]],
                })
                console.print(f"  [dim]📀 {provider_name}:{aid[:8]}… → {album.name}[/]")
            else:
                results.append({"id": aid, "error": "not found"})
        return results

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search the web for series info. Max 3 searches.

        Returns list of {title, url, snippet}. Good queries:
        - '"Series Name" Hörspiel Episodenliste'
        - 'site:hoerspiele.de "Series Name"'
        """
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            return [{"result": f"web_search limit reached ({ctx.deps._search_count}/{ctx.deps._MAX_SEARCHES}). Do not call web_search again; proceed with current knowledge."}]
        ctx.deps._search_count += 1

        from lauschi_catalog.search import brave_search

        results = brave_search(query, count=5)
        n = len([r for r in results if "error" not in r])
        console.print(f"  [dim]🔍 web_search({query!r}) → {n} results[/]")
        return results

    @agent.tool
    def fetch_page(ctx: RunContext[Deps], url: str) -> str:
        """Fetch a URL and extract text content. Max 2 fetches.

        Useful for hoerspiele.de series pages with episode listings.
        """
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            return f"fetch_page limit reached ({ctx.deps._fetch_count}/{ctx.deps._MAX_FETCHES}). Do not call fetch_page again; proceed with current knowledge."
        ctx.deps._fetch_count += 1

        from lauschi_catalog.search import fetch_page as _fetch

        content = _fetch(url, max_chars=4000)
        console.print(f"  [dim]📄 fetch_page({url[:60]}…) → {len(content)} chars[/]")
        return content

    return agent


# ── Prompt builder ─────────────────────────────────────────────────────────

def _build_prompt(curation: dict) -> str:
    albums = curation.get("albums", [])
    review = curation.get("review", {})

    included = sorted(
        [a for a in albums if a.get("include")],
        key=lambda a: (
            a.get("episode_num") is None, a.get("episode_num"),
            a.get("release_date") or "",
            a["title"],
        ),
    )
    excluded = [a for a in albums if not a.get("include")]

    lines = [
        f"## Series: {curation.get('title', '?')} (id: {curation.get('id', '?')})",
        f"Episode pattern: {curation.get('episode_pattern', 'none')}",
        f"Provider artist IDs: {curation.get('provider_artist_ids', {})}",
        "",
        f"### Included albums ({len(included)})",
    ]

    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        lines.append(
            f"  ✅ [{a.get('provider', '?')}] {ep_str}{a['title']}"
            f"{rel_str} [{a['album_id']}]",
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded[:30]:
        reason = a.get("exclude_reason", "")
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        lines.append(
            f"  ❌ [{a.get('provider', '?')}] {a['title']}"
            f"{rel_str} [{a['album_id']}]"
            f"{f' — {reason}' if reason else ''}",
        )

    overrides = review.get("overrides", [])
    splits = review.get("splits", [])

    if overrides:
        lines.append(f"\n### First reviewer overrides ({len(overrides)})")
        for o in overrides:
            lines.append(
                f"  🔄 {o.get('action', '?')}: [{o.get('provider', '?')}] "
                f"{o['album_id']} — {o.get('reason', '')}",
            )

    if splits:
        lines.append(f"\n### First reviewer split proposals ({len(splits)})")
        for s in splits:
            lines.append(
                f"  ✂️  {s.get('new_series_title', '?')} ({s.get('new_series_id', '?')}): "
                f"{len(s.get('album_ids', []))} albums — {s.get('reason', '')}",
            )

    # Series facts discovered by curate / reviewed by review
    facts = curation.get("series_facts")
    if facts:
        lines.append("\n### Series facts (proposed by curate/review)")
        for e in facts.get("era_boundaries", []):
            status = f" [{e.get('verify_status') or 'unverified'}]" if e.get('verify_status') else ""
            lines.append(
                f"  • Era: {e.get('label', '?')} ({e.get('release_date_range', '?')}){status}"
            )
        for g in facts.get("known_gaps", []):
            status = f" [{g.get('verify_status') or 'unverified'}]" if g.get('verify_status') else ""
            lines.append(
                f"  • Known gap: episode {g.get('number', '?')} — {g.get('reason', '')}{status}"
            )
        for s in facts.get("sub_series", []):
            status = f" [{s.get('verify_status') or 'unverified'}]" if s.get('verify_status') else ""
            lines.append(
                f"  • Sub-series: {s.get('label', '?')} — {s.get('reason', '')}{status}"
            )

    # Per-category decisions + reasoning. Without this, the verifier
    # only sees outcomes (overrides, splits) and is asked to agree
    # without knowing WHY the first reviewer chose them. 4-eye is
    # only meaningful if the second reviewer can challenge the
    # rationale, not just the action.
    decisions = review.get("decisions") or {}
    if decisions:
        lines.append("\n### First reviewer per-category decisions")
        for category in (
            "duplicates", "sub_series", "gaps",
            "pattern", "outliers", "cross_provider",
        ):
            d = decisions.get(category) or {}
            if not d:
                continue
            verdict = d.get("verdict", "?")
            reasoning = (d.get("reasoning") or "").strip()[:300]
            lines.append(f"  • {category}: {verdict}")
            if reasoning:
                lines.append(f"      {reasoning}")

    summary = (review.get("summary") or "").strip()
    if summary:
        lines.append(f"\n### First reviewer summary\n{summary[:500]}")

    lines.append(
        "\nVerify the above. Challenge the rationale, not just the actions. "
        "Spot-check with tools when uncertain. Give your verdict.",
    )
    return "\n".join(lines)


# ── Core verify ────────────────────────────────────────────────────────────

async def verify_one(
    series_id: str,
    providers: list[CatalogProvider],
    *,
    model_name: str = _VERIFY_MODEL,
    timeout: int = 300,
    force: bool = False,
) -> VerifyResult | None:
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/red]")
        raise SystemExit(1)

    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Not found: {path}[/red]")
        return None

    curation = json.loads(path.read_text())

    # Pipeline status check, gated by lifecycle staleness so a re-curate
    # or re-review flushes prior verify outputs that no longer apply.
    review = curation.get("review", {})
    status = review.get("status")

    # Verify is the second-opinion check on a prior review's decisions.
    # Fresh curations that haven't been reviewed yet have nothing to
    # verify — handing the agent an empty review block produces noise.
    # This guard sits ahead of --force on purpose: forcing verification
    # of nothing is never the intent.
    if not review:
        console.print(
            f"[dim]Skipping {series_id}: no review block "
            f"(run review first)[/dim]",
        )
        return None

    if not force:
        if review_is_stale(curation):
            # Verifying against a stale review would stamp a verdict on
            # outdated decisions. Refuse and point at the upstream step.
            console.print(
                f"[yellow]Skipping {series_id}: review is stale "
                f"(curate ran after last review). Run review first.[/yellow]",
            )
            return None
        # Trust the status-based skip only when verify isn't stale —
        # a stale verify falls through and re-runs.
        if not verification_is_stale(curation):
            if status in ("approved", "ai_verified"):
                console.print(f"[dim]Skipping {series_id} (already {status})[/dim]")
                return None
            if status == "rejected":
                console.print(f"[dim]Skipping {series_id} (rejected)[/dim]")
                return None

    agent = _build_verify_agent(model_name, api_key)
    prompt = _build_prompt(curation)

    for attempt in range(_MAX_RETRIES):
        # Fresh deps each outer attempt so a prior failed attempt's
        # exhausted tool counters (web_search/fetch/album_details)
        # don't starve the next one. Matches review.py's pattern.
        deps = Deps(providers=providers, series_id=series_id, curation=curation)
        try:
            async def _run():
                async with agent.iter(
                    prompt, deps=deps,
                    usage_limits=UsageLimits(request_limit=20),
                ) as run:
                    async for node in run:
                        if not hasattr(node, "model_response"):
                            continue
                        for part in node.model_response.parts:
                            text = getattr(part, "content", None)
                            if isinstance(text, str) and len(text.strip()) > 80:
                                kind = getattr(part, "part_kind", "")
                                if kind == "thinking":
                                    console.print(Panel(
                                        text.strip()[:500],
                                        border_style="dim", title="💭",
                                        padding=(0, 1),
                                    ))
                    return run.result.output

            result = await asyncio.wait_for(_run(), timeout=timeout)
            return result
        except asyncio.TimeoutError:
            # Timeout on a 600s budget means we've already burned the
            # full budget; retrying would just burn another. Fail fast.
            raise
        except Exception as e:
            # Only retry transient transport/5xx failures. Auth errors
            # (401), validation failures, and other definitive errors
            # propagate immediately so we don't waste retries (and 5s
            # delays each) on something that won't fix itself.
            if is_retryable(e) and attempt < _MAX_RETRIES - 1:
                err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
                console.print(f"[yellow]Attempt {attempt + 1} failed: {err}[/yellow]")
                await asyncio.sleep(_RETRY_DELAY)
            else:
                raise


def _match_verdict(
    verdicts: dict[tuple[str, str | int], FactVerdict],
    fact_type: str,
    identifier: str | int,
) -> tuple[FactVerdict, tuple[str, str | int]] | None:
    """Lookup a FactVerdict with type coercion for known gaps.

    LLMs may return ``identifier: "156"`` (string) when the fact has
    ``number: 156`` (int). We coerce int-like strings and strip/lower
    labels so the match survives schema drift.

    Returns ``(verdict, matched_key)`` so the caller knows which raw
    verdict was consumed and can exclude it from the unmatched warning.
    """
    candidates: list[tuple[str | int, tuple[str, str | int]]] = [
        (identifier, (fact_type, identifier)),
    ]
    if isinstance(identifier, str) and fact_type == "known_gap":
        try:
            candidates.append((int(identifier), (fact_type, int(identifier))))
        except ValueError:
            pass
    elif isinstance(identifier, int) and fact_type == "known_gap":
        candidates.append((str(identifier), (fact_type, str(identifier))))
    if isinstance(identifier, str):
        candidates.append((identifier.strip(), (fact_type, identifier.strip())))
    # Try each candidate form
    for _, key in candidates:
        if key in verdicts:
            return verdicts[key], key
    # Case-fold fallback for labels
    if isinstance(identifier, str):
        target = identifier.strip().casefold()
        for (ft, ident), v in verdicts.items():
            if ft == fact_type and isinstance(ident, str) and ident.strip().casefold() == target:
                return v, (ft, ident)
    return None


def apply_verification(
    series_id: str,
    result: VerifyResult,
    *,
    model_name: str = _VERIFY_MODEL,
    dry_run: bool = False,
) -> str:
    """Store verification result. Returns action: 'approved' or 'escalated'."""
    path = CURATION_DIR / f"{series_id}.json"
    data = json.loads(path.read_text())
    review = data.setdefault("review", {})
    now = datetime.now(tz=UTC).isoformat()

    # Per-fact verification: stamp confirmations and flag disagreements
    series_facts = data.get("series_facts")
    if series_facts:
        # Build lookup: (fact_type, identifier) -> verdict
        verdicts = {
            (v.fact_type, v.identifier): v
            for v in result.fact_verdicts
        }

        matched: set[tuple[str, str | int]] = set()

        for e in series_facts.get("era_boundaries", []):
            label = e.get("label", "")
            match = _match_verdict(verdicts, "era_boundary", label)
            if match:
                v, matched_key = match
                matched.add(matched_key)
                if v.agree:
                    e["confirmed_by"] = "verify"
                    # Only stamp confirmed_at on first confirmation; re-agreement
                    # leaves the original timestamp intact for the audit trail.
                    if not e.get("confirmed_at"):
                        e["confirmed_at"] = now
                    e["verify_status"] = "agreed"
                else:
                    # Disagreement wipes any stale confirmation so the fact
                    # can't slip through _filter_confirmed_facts.
                    e["confirmed_by"] = None
                    e["confirmed_at"] = None
                    e["verify_status"] = "disagreed"
                    e["verify_reasoning"] = v.reason

        for g in series_facts.get("known_gaps", []):
            num = g.get("number")
            match = _match_verdict(verdicts, "known_gap", num)
            if match:
                v, matched_key = match
                matched.add(matched_key)
                if v.agree:
                    g["confirmed_by"] = "verify"
                    if not g.get("confirmed_at"):
                        g["confirmed_at"] = now
                    g["verify_status"] = "agreed"
                else:
                    g["confirmed_by"] = None
                    g["confirmed_at"] = None
                    g["verify_status"] = "disagreed"
                    g["verify_reasoning"] = v.reason

        for s in series_facts.get("sub_series", []):
            label = s.get("label", "")
            match = _match_verdict(verdicts, "sub_series", label)
            if match:
                v, matched_key = match
                matched.add(matched_key)
                if v.agree:
                    s["confirmed_by"] = "verify"
                    if not s.get("confirmed_at"):
                        s["confirmed_at"] = now
                    s["verify_status"] = "agreed"
                else:
                    s["confirmed_by"] = None
                    s["confirmed_at"] = None
                    s["verify_status"] = "disagreed"
                    s["verify_reasoning"] = v.reason

        # Warn about verdicts that didn't match any fact — these are
        # likely hallucinations or identifier drift and will be silently
        # ignored if not surfaced.
        unmatched = set((v.fact_type, v.identifier) for v in result.fact_verdicts) - matched
        for ft, ident in sorted(unmatched):
            console.print(
                f"  [yellow]⚠ Verify verdict {ft!r} ({ident!r}) "
                f"did not match any fact in {series_id}[/yellow]",
            )

        data["series_facts"] = series_facts

    review["verification"] = {
        "model": model_name,
        "verified_at": now,
        "approve": result.approve,
        "concerns": result.concerns,
        "override_verdicts": [v.model_dump() for v in result.override_verdicts],
        "split_verdicts": [v.model_dump() for v in result.split_verdicts],
        "fact_verdicts": [v.model_dump() for v in result.fact_verdicts],
    }

    # Structural disagreements (overrides/splits) still matter
    disagreements = (
        [v for v in result.override_verdicts if not v.agree]
        + [v for v in result.split_verdicts if not v.agree]
    )

    # Escalate ONLY when genuinely incoherent (approve=False).
    # Fact disagreements alone flag the facts but let the series pass.
    if not result.approve:
        action = "escalated"
        review["status"] = "escalated"
    elif disagreements:
        action = "approved_with_flags"
        review["status"] = "ai_verified"
    else:
        action = "approved"
        review["status"] = "approved"

    if not dry_run:
        canonicalize(data)
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False))

    return action


# ── CLI ────────────────────────────────────────────────────────────────────

def _init_providers(provider: str) -> list[CatalogProvider]:
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider())
        except SystemExit:
            console.print("[yellow]Spotify not configured[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider())
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found[/yellow]")
    return providers


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Verify all curated series")
@click.option("--force", is_flag=True, help="Re-verify even if already verified")
@click.option("--dry-run", is_flag=True, help="Don't write changes")
@click.option("--model", default=_VERIFY_MODEL, help="Verification model")
@click.option("--timeout", default=300)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
def verify(
    series_id: str | None,
    run_all: bool,
    force: bool,
    dry_run: bool,
    model: str,
    timeout: int,
    provider: str,
):
    """4-eye verification: second model checks curation decisions.

    Auto-approves when both models agree. Escalates disagreements for
    human review.
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    providers = _init_providers(provider)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    approved = 0
    escalated = 0
    skipped = 0
    failed = 0

    flagged = 0
    for path in paths:
        sid = path.stem
        console.print(f"\n[bold]Verifying {sid}...[/bold]")

        try:
            result = asyncio.run(
                verify_one(
                    sid, providers,
                    model_name=model, timeout=timeout, force=force,
                ),
            )
        except Exception as e:
            console.print(f"[red]Failed: {e}[/red]")
            failed += 1
            continue

        if result is None:
            skipped += 1
            continue

        action = apply_verification(sid, result, model_name=model, dry_run=dry_run)

        if action == "approved":
            approved += 1
            console.print(f"  [green]✓ Approved[/green]")
            if result.concerns:
                console.print(f"  [dim]Concerns: {result.concerns}[/dim]")
        elif action == "approved_with_flags":
            flagged += 1
            console.print(f"  [green]✓ Approved[/green] [yellow](flagged {len([v for v in result.fact_verdicts if not v.agree])} facts)[/yellow]")
            if result.concerns:
                console.print(f"  [dim]Concerns: {result.concerns}[/dim]")
        else:
            escalated += 1
            console.print(f"  [yellow]⚠ Escalated for human review[/yellow]")
            console.print(f"  Concerns: {result.concerns}")

    console.print(
        f"\n[bold]Results:[/bold] {approved} approved, {flagged} approved-with-flags, "
        f"{escalated} escalated, {skipped} skipped, {failed} failed",
    )
    if dry_run:
        console.print("[dim]Dry run, no changes written.[/dim]")
