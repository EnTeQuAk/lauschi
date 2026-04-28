"""AI-assisted review of curated series data.

Reads a curation JSON, analyzes it for issues (sub-series duplicates, gaps,
era variants), and writes non-destructive review decisions: overrides to
exclude, additions for gaps, and split proposals for content that belongs
in a separate series entry.

Ported from scripts/review-series.py with multi-provider support.
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import click
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich.console import Console
from rich.panel import Panel

from lauschi_catalog.catalog.analysis import analyze_series, effective_albums
from lauschi_catalog.providers import CatalogProvider

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL = "kimi-k2.6"
_MAX_RETRIES = 3
_RETRY_DELAY = 5


# ── Output models ──────────────────────────────────────────────────────────

class ReviewOverride(BaseModel):
    album_id: str
    provider: str
    action: str  # "exclude" or "include"
    reason: str


class SplitProposal(BaseModel):
    new_series_id: str
    new_series_title: str
    album_ids: list[str]
    provider: str
    reason: str


class AddedAlbum(BaseModel):
    album_id: str
    provider: str
    title: str
    episode_num: int | None = None
    # ``include`` defaults to True: an explicit add means the agent
    # wants this album in the curation. ``exclude_reason`` mirrors the
    # shape of regular albums in data["albums"] so save_review can
    # merge without post-processing.
    include: bool = True
    exclude_reason: str | None = None
    # URL the agent cited as evidence the episode exists on the provider.
    # Empty string for legacy entries; new adds require a non-empty value
    # at tool-call time (see review_validation.validate_add_evidence).
    evidence_url: str = ""


class ReviewResult(BaseModel):
    overrides: list[ReviewOverride] = Field(default_factory=list)
    splits: list[SplitProposal] = Field(default_factory=list)
    added_albums: list[AddedAlbum] = Field(default_factory=list)
    pattern_update: str | list[str] | None = None
    notes: str = ""


# ── Dependencies ───────────────────────────────────────────────────────────

@dataclass
class Deps:
    providers: list[CatalogProvider]
    curation: dict
    added_albums: list[dict] = field(default_factory=list)
    seen_details: dict[str, dict] = field(default_factory=dict)
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _details_count: int = field(default=0, init=False)
    _add_count: int = field(default=0, init=False)
    _pattern_count: int = field(default=0, init=False)
    # Hard caps prevent runaway tool loops. The previous design exposed a
    # provider-search tool that hallucinated titles and burned 100+ requests
    # on TKKG-sized series. add_album and update_episode_pattern are bounded
    # because they mutate curation state, where a loop pollutes data not
    # just budget.
    _MAX_SEARCHES: int = 5
    _MAX_FETCHES: int = 3
    _MAX_DETAILS: int = 10
    _MAX_ADDS: int = 5
    _MAX_PATTERN_UPDATES: int = 3


_SYSTEM_PROMPT = """\
You review curated Hörspiel series for quality issues in the lauschi
catalog, a privacy-first kids audio player for the DACH region.

## Your role

A first AI (curate) has already classified every album in this series as
included or excluded, and episode numbers were extracted by deterministic
regex. You don't re-classify albums one by one. You **judge the
structure**: does this curation hang together as a coherent series, or
are there defects that should be fixed before it ships to families?

The user prompt carries:
1. A pre-computed structural analysis of the curation
2. The full lists of included and excluded albums

Use the analysis as evidence; don't recompute what's already there.

## Reading the analysis

- **title_clusters** groups titles by structural shape. One dominant
  cluster is healthy. Multiple clusters with distinct prefixes
  ("Junior - Folge n", "Gute-Nacht-Geschichten - Folge n", "Benjamin
  Minis - Folge n") are **structural evidence of sub-series mixed
  in**. Propose a split for each non-dominant cluster of 2+ albums.
  Sub-series belong in their own catalog entry even when they're
  part of the same franchise — kids navigating by episode number
  shouldn't see "Folge 5" point to three different stories. Don't
  rationalize this as "intentional editorial choice."
- **outliers** are titles whose shape appears once. Often box sets,
  specials, compilations, or unrelated content that slipped in.
- **duplicates_within_provider** is a real defect: same provider + same
  episode_num. Two album_ids appearing as the same episode means kids
  see the story twice. **Propose an override that excludes one** —
  default is to keep the older release; format variants
  (Kopfhörer-Hörspiel, "Neuaufnahme", remasters) get excluded since
  the regular version covers the same story. Use album_details to
  compare track listings if you're not sure which to keep.
- **cross_provider_coverage** shows asymmetry. Episodes missing on one
  provider are usually content rotation (the provider hasn't published
  it), not a curation defect — but verify with web_search if a long
  contiguous stretch is missing.
- **pattern_coverage** below ~90% with otherwise-clean titles signals a
  broken episode_pattern. Use update_episode_pattern to propose a fix.
- **gaps** lists missing episode numbers. Same caveat as
  cross_provider_coverage: usually content rotation, not a defect.
  Verify before flagging.
- **common_words** helps you confirm the series identity from titles.

## Tools

- **album_details** (max 10): fetch track listings for ambiguous albums.
  Useful when deciding which of two duplicates to keep.
- **web_search** (max 5): research the series. Best for verifying gaps,
  identifying sub-series, confirming era variants. Good queries:
  - `"Series Name" Hörspiel Episodenliste`
  - `site:hoerspiele.de "Series Name"`
  - `"Series Name" Junior` to confirm a sub-series exists
- **fetch_page** (max 3): drill into a search hit. hoerspiele.de carries
  authoritative episode lists for German Hörspiele.
- **add_album** (max 5): add a missing album. Last resort — only when web
  evidence shows the episode is on the provider but wasn't matched by
  the artist ID. Requires an ``evidence_url`` parameter pointing to the
  search result or page that confirms the episode. The tool refuses if
  you haven't called web_search or fetch_page first, so research
  before you add.
- **update_episode_pattern** (max 3): propose a new regex pattern. Each
  pattern needs exactly one capture group. Patterns are tried in order.

## Output

- **overrides**: exclude actions for albums that shouldn't be included.
- **splits**: proposed sub-series for clusters that belong elsewhere.
- **added_albums**: filled by add_album calls.
- **pattern_update**: new episode_pattern when needed.
- **notes**: anything noteworthy that doesn't fit elsewhere, and any
  uncertainty you couldn't resolve.

## Rules

- Trust the structural analysis. It's deterministic; if it shows
  duplicates_within_provider entries or distinct title clusters, those
  are facts, not suggestions. Propose concrete actions (overrides,
  splits) when the evidence is clear.
- The verify step (4-eye check) catches over-reach. It's better to
  propose an action with reasoning than to defer everything to notes.
- Era variants stay together: when two clusters share a single
  coherent numbering scheme (e.g., "n" for older releases and
  "folge n" for newer, both numbering the same series), do NOT split.
  Format-change clusters are not sub-series.
- Don't fill gaps with add_album unless web evidence confirms the
  episode is on the provider under a different artist account.
- Use `notes` for genuine ambiguity — not for explaining away clear
  defects the analysis already surfaced.
"""


def _build_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, ReviewResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)

    agent: Agent[Deps, ReviewResult] = Agent(
        model,
        output_type=ReviewResult,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search the web for series info.

        Capped at Deps._MAX_SEARCHES calls per review run. Returns a list of
        ``{title, url, snippet}`` results. Good queries:
        - ``"Series Name" Hörspiel Episodenliste``
        - ``site:hoerspiele.de "Series Name"``
        """
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            return [{"error": f"Search limit reached (max {ctx.deps._MAX_SEARCHES})."}]
        ctx.deps._search_count += 1

        from lauschi_catalog.search import brave_search

        results = brave_search(query, count=5)
        n = len([r for r in results if "error" not in r])
        console.print(
            f"  [dim]🔍 web_search({query!r}) → {n} results "
            f"[{ctx.deps._search_count}/{ctx.deps._MAX_SEARCHES}][/]",
        )
        return results

    @agent.tool
    def fetch_page(ctx: RunContext[Deps], url: str) -> str:
        """Fetch a URL and return its text content.

        Capped at Deps._MAX_FETCHES calls per review run. Useful for
        drilling into hoerspiele.de series pages with authoritative
        episode listings.
        """
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            return f"Fetch limit reached (max {ctx.deps._MAX_FETCHES})."
        ctx.deps._fetch_count += 1

        from lauschi_catalog.search import fetch_page as _fetch

        content = _fetch(url, max_chars=4000)
        console.print(
            f"  [dim]📄 fetch_page({url[:60]}…) → {len(content)} chars "
            f"[{ctx.deps._fetch_count}/{ctx.deps._MAX_FETCHES}][/]",
        )
        return content

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], provider_name: str, album_id: str,
    ) -> dict:
        """Get full album details from a provider.

        Capped at Deps._MAX_DETAILS calls per review run. Cache hits don't
        count against the cap.
        """
        key = f"{provider_name}:{album_id}"
        if key in ctx.deps.seen_details:
            return ctx.deps.seen_details[key]

        if ctx.deps._details_count >= ctx.deps._MAX_DETAILS:
            return {"error": f"Album details limit reached (max {ctx.deps._MAX_DETAILS})."}
        ctx.deps._details_count += 1

        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return {"error": f"Provider {provider_name} not available"}
        album = target.album_details(album_id)
        if not album:
            return {"error": "Album not found"}
        result = {
            "id": album.id, "name": album.name, "provider": provider_name,
            "total_tracks": album.total_tracks, "label": album.label,
            "tracks": [{"name": t.name, "duration_ms": t.duration_ms} for t in album.tracks],
        }
        ctx.deps.seen_details[key] = result
        console.print(
            f"  [dim]📀 album_details({provider_name}:{album_id[:8]}…) "
            f"→ {album.total_tracks} tracks "
            f"[{ctx.deps._details_count}/{ctx.deps._MAX_DETAILS}][/]",
        )
        return result

    @agent.tool
    def add_album(
        ctx: RunContext[Deps],
        provider_name: str,
        album_id: str,
        evidence_url: str,
    ) -> str:
        """Add a missing album to the series, recovered from the provider.

        ``evidence_url`` must point to a search result or page that
        confirms this episode belongs to the series. The tool refuses
        when the URL is missing or no prior web_search/fetch_page has
        been run; this prevents the agent from inventing album_ids.

        Capped at Deps._MAX_ADDS. Duplicates and not-found album IDs do
        not count against the cap.
        """
        from lauschi_catalog.commands.review_validation import validate_add_evidence

        evidence_error = validate_add_evidence(ctx.deps, evidence_url)
        if evidence_error:
            return evidence_error

        existing = {a["album_id"] for a in ctx.deps.curation.get("albums", [])}
        if album_id in existing:
            console.print(f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → already exists[/]")
            return f"Already exists: {album_id}"

        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return f"Provider {provider_name} not available"

        album = target.album_details(album_id)
        if not album:
            console.print(f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → not found[/]")
            return f"Not found: {album_id}"

        if ctx.deps._add_count >= ctx.deps._MAX_ADDS:
            return f"Add limit reached (max {ctx.deps._MAX_ADDS})."
        ctx.deps._add_count += 1

        from lauschi_catalog.catalog.matcher import extract_episode
        pattern = ctx.deps.curation.get("episode_pattern")
        episode_num = extract_episode(pattern, album.name)

        new_album = {
            "album_id": album_id,
            "provider": provider_name,
            "include": True,
            "episode_num": episode_num,
            "title": album.name,
            "exclude_reason": None,
            "evidence_url": evidence_url,
        }
        ctx.deps.added_albums.append(new_album)
        ep_str = f" (episode {episode_num})" if episode_num else ""
        console.print(
            f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → {album.name}{ep_str} "
            f"[{ctx.deps._add_count}/{ctx.deps._MAX_ADDS}][/]",
        )
        return f"Added: {album.name}{ep_str} (evidence: {evidence_url})"

    @agent.tool
    def update_episode_pattern(
        ctx: RunContext[Deps], patterns: list[str],
    ) -> str:
        """Validate a candidate episode pattern and preview its effect.

        Each pattern must have exactly 1 capture group. Patterns are tried
        in order. This tool does **not** mutate the curation. Set the
        chosen pattern in the ``pattern_update`` field of your output;
        ``save_review`` applies it deterministically after this run.

        Capped at Deps._MAX_PATTERN_UPDATES calls. The agent should
        converge on one pattern, not iterate.
        """
        import re as _re
        for p in patterns:
            try:
                c = _re.compile(p)
            except _re.error as e:
                return f"Invalid pattern {p!r}: {e}"
            if c.groups != 1:
                return f"Pattern {p!r}: need 1 capture group, got {c.groups}"

        if ctx.deps._pattern_count >= ctx.deps._MAX_PATTERN_UPDATES:
            return f"Pattern update limit reached (max {ctx.deps._MAX_PATTERN_UPDATES})."
        ctx.deps._pattern_count += 1

        from lauschi_catalog.catalog.matcher import preview_episode_pattern

        candidate = patterns[0] if len(patterns) == 1 else patterns
        would_change = preview_episode_pattern(
            ctx.deps.curation.get("albums", []), candidate,
        )
        console.print(
            f"  [dim]📝 update_episode_pattern preview → {candidate} "
            f"({would_change} would change) "
            f"[{ctx.deps._pattern_count}/{ctx.deps._MAX_PATTERN_UPDATES}][/]",
        )
        return (
            f"Pattern {candidate!r} is valid. Applying it would re-extract "
            f"episode_num for {would_change} album(s). Set this in "
            f"pattern_update to apply."
        )

    return agent


def _build_prompt(curation: dict) -> str:
    """Render the review prompt: structural analysis + full album lists.

    Verify uses the same shape so the agent sees a consistent picture across
    pipeline stages. Including the full lists inline lets us drop the
    ``show_series`` tool: there's nothing left for it to fetch.
    """
    title = curation.get("title", "?")
    series_id = curation.get("id", "?")
    pattern = curation.get("episode_pattern", "none")
    artist_ids = curation.get("provider_artist_ids", {})
    content_type = curation.get("content_type", "hoerspiel")
    analysis = analyze_series(curation)

    albums = curation.get("albums", [])
    review = curation.get("review", {})
    excluded_via_override = {
        o["album_id"]
        for o in review.get("overrides", [])
        if o["action"] == "exclude"
    }

    included = sorted(
        [
            a for a in albums
            if a.get("include") and a["album_id"] not in excluded_via_override
        ],
        key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
    )
    excluded = [a for a in albums if not a.get("include")]

    lines = [
        f"## Series: {title} (id: {series_id})",
        f"Content type: {content_type}",
        f"Episode pattern: {pattern}",
        f"Provider artist IDs: {artist_ids}",
        "",
    ]
    if content_type == "music":
        lines.extend([
            "### Music artist — different rules apply",
            "This curation is a children's MUSIC artist, not a Hörspiel"
            " series. Albums are standalone music releases. Do NOT propose"
            " excluding albums for being 'music singles' — that is the"
            " expected content here. Episode numbers, episode_pattern,"
            " gaps, and sub-series clustering are not relevant. Look only"
            " for: cross-provider inconsistencies (same album included on"
            " one provider but excluded on another), compilations vs"
            " original releases, and accidental Hörspiel/audiobook content"
            " mixed into a music artist.",
            "",
        ])
    lines.extend([
        "### Structural analysis",
        json.dumps(analysis, indent=2, ensure_ascii=False),
        "",
        f"### Included albums ({len(included)})",
    ])
    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        lines.append(
            f"  ✅ [{a.get('provider', '?')}] {ep_str}{a['title']} "
            f"[{a['album_id']}]",
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded[:30]:
        reason = a.get("exclude_reason", "")
        suffix = f" — {reason}" if reason else ""
        lines.append(
            f"  ❌ [{a.get('provider', '?')}] {a['title']} "
            f"[{a['album_id']}]{suffix}",
        )
    if len(excluded) > 30:
        lines.append(f"  … and {len(excluded) - 30} more")

    lines.append(
        "\nReview the structure. Propose overrides, splits, pattern_update, "
        "and added_albums where the analysis or your judgment warrants. "
        "Use web_search and fetch_page when the analysis raises a question "
        "you can't answer from the data alone.",
    )
    return "\n".join(lines)


async def _run_review(
    curation: dict,
    providers: list[CatalogProvider],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 300,
) -> ReviewResult:
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/red]")
        raise SystemExit(1)

    deps = Deps(providers=providers, curation=curation)
    agent = _build_agent(model_name, api_key)

    prompt = _build_prompt(curation)

    for attempt in range(_MAX_RETRIES):
        try:
            async def _run():
                async with agent.iter(
                    prompt, deps=deps,
                    usage_limits=UsageLimits(request_limit=40),
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
            # The add_album tool appends to deps.added_albums as a side
            # effect, but pydantic-ai's structured output is built from
            # what the model returned, not from deps state. Merge any
            # tool-recorded adds the model didn't echo back into the
            # final result so save_review sees them.
            _merge_tool_adds(result, deps)
            _warn_if_notes_smell_structured(result)
            return result
        except Exception as e:
            if attempt < _MAX_RETRIES - 1:
                console.print(f"[yellow]Attempt {attempt + 1} failed: {e}[/yellow]")
                await asyncio.sleep(_RETRY_DELAY)
            else:
                raise


_STRUCTURED_LEAK_MARKERS = (
    '"splits":', "'splits':",
    '"overrides":', "'overrides':",
    '"added_albums":', "'added_albums':",
    '"new_series_id":', "'new_series_id':",
    '"album_ids":', "'album_ids':",
)


def _warn_if_notes_smell_structured(result: ReviewResult) -> None:
    """Detect when the model jammed structured output into ``notes``.

    Some models (kimi at certain temperatures) return prose summary plus
    raw JSON of the structured fields all bundled into notes, instead of
    populating overrides/splits/added_albums directly. The empty action
    fields then look like a clean review when in fact the agent proposed
    significant actions. Warn loudly so a human can re-run or post-edit.
    """
    if any(m in result.notes for m in _STRUCTURED_LEAK_MARKERS):
        no_actions = (
            not result.overrides
            and not result.splits
            and not result.added_albums
            and not result.pattern_update
        )
        if no_actions:
            console.print(
                "[bold red]⚠ MALFORMED OUTPUT:[/] the model put structured "
                "output (splits/overrides/added_albums) inside the notes "
                "field instead of the dedicated fields. The recommendations "
                "live in notes as JSON-like text but are NOT applied. Re-run "
                "with --force or a different --model.",
            )


def _merge_tool_adds(result: ReviewResult, deps: Deps) -> None:
    """Ensure deps.added_albums is reflected in result.added_albums.

    Idempotent: skips IDs already in the result. Mutates ``result`` in
    place; the result object is returned to the caller separately.
    """
    seen = {a.album_id for a in result.added_albums}
    for entry in deps.added_albums:
        if entry["album_id"] in seen:
            continue
        result.added_albums.append(
            AddedAlbum(
                album_id=entry["album_id"],
                provider=entry["provider"],
                title=entry["title"],
                episode_num=entry.get("episode_num"),
                include=entry.get("include", True),
                exclude_reason=entry.get("exclude_reason"),
                evidence_url=entry.get("evidence_url", ""),
            ),
        )
        seen.add(entry["album_id"])


def save_review(series_id: str, result: ReviewResult) -> Path:
    """Save review result into the curation JSON.

    Updates the review block in place: overrides/splits/added_albums/
    pattern_update/notes/reviewed_at are replaced with this run's
    output, but any other fields the verify step or human reviewers
    may have added (status, verification, reviewed_by, etc.) are
    preserved. The review step writes review findings; downstream
    pipeline state belongs to verify.
    """
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Curation file not found: {path}[/red]")
        raise SystemExit(1)

    data = json.loads(path.read_text())
    review_block = data.setdefault("review", {})
    review_block["overrides"] = [o.model_dump() for o in result.overrides]
    review_block["splits"] = [s.model_dump() for s in result.splits]
    review_block["added_albums"] = [a.model_dump() for a in result.added_albums]
    review_block["pattern_update"] = result.pattern_update
    review_block["notes"] = result.notes
    review_block["reviewed_at"] = datetime.now(UTC).isoformat()

    # Merge added albums into the main albums list before re-extracting,
    # so any new ones get their episode_num under the (possibly updated)
    # pattern in the same pass.
    if result.added_albums:
        existing_ids = {a["album_id"] for a in data.get("albums", [])}
        for added in result.added_albums:
            if added.album_id not in existing_ids:
                data.setdefault("albums", []).append(added.model_dump())

    # Apply the pattern update deterministically. The review tool only
    # previews; the source of truth is what the agent put in its output.
    if result.pattern_update:
        from lauschi_catalog.catalog.matcher import apply_episode_pattern

        data["episode_pattern"] = result.pattern_update
        data["albums"] = apply_episode_pattern(
            data.get("albums", []), result.pattern_update,
        )

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Review all curated series")
@click.option("--force", is_flag=True, help="Re-review even if already approved or ai_verified")
@click.option("--model", default=_DEFAULT_MODEL)
@click.option("--timeout", default=300)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
def review(
    series_id: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
):
    """AI-review a curated series for quality issues."""
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider())
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider())
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if run_all:
        paths = sorted(CURATION_DIR.glob("*.json"))
    else:
        paths = [CURATION_DIR / f"{series_id}.json"]

    skipped = 0
    for path in paths:
        if not path.exists():
            console.print(f"[yellow]Skipping {path.stem}: no curation file[/yellow]")
            continue

        curation = json.loads(path.read_text())

        # Don't clobber already-approved reviews. The verify step locks a
        # curation when both AIs agree; re-running review would replace
        # that human-trusted state with fresh AI output, including any
        # human-added overrides. Use --force to override (e.g., after a
        # re-curation pulled in new episodes).
        existing_status = curation.get("review", {}).get("status")
        if not force and existing_status in ("approved", "ai_verified"):
            console.print(
                f"[dim]Skipping {path.stem} (already {existing_status}; "
                f"use --force to re-review)[/dim]",
            )
            skipped += 1
            continue

        console.print(f"\n[bold]Reviewing {curation.get('title', path.stem)}...[/bold]")

        result = asyncio.run(
            _run_review(curation, providers, model_name=model, timeout=timeout),
        )

        # Always persist the review block — even when no actions were
        # proposed, the agent's notes are valuable provenance for human
        # auditors. Otherwise insightful reasoning gets lost on stdout.
        save_path = save_review(path.stem, result)
        console.print(
            f"  {len(result.overrides)} overrides, {len(result.splits)} splits, "
            f"{len(result.added_albums)} added"
            + (", pattern_update" if result.pattern_update else ""),
        )
        console.print(f"  [green]Saved to {save_path}[/green]")

        if result.notes:
            console.print(f"  Notes: {result.notes}")
