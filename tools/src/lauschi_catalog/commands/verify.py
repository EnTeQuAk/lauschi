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

import click
import requests
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.loader import load_raw, save_raw, SERIES_YAML
from lauschi_catalog.providers import CatalogProvider

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_VERIFY_MODEL = "minimax-m2.5"
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


class VerifyResult(BaseModel):
    series_id: str
    approve: bool = Field(
        description="True if the curation is correct overall. "
        "False if issues need human attention.",
    )
    override_verdicts: list[OverrideVerdict] = Field(default_factory=list)
    split_verdicts: list[SplitVerdict] = Field(default_factory=list)
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
    _lookup_count: int = field(default=0, init=False)
    _MAX_LOOKUPS: int = 2


_SYSTEM_PROMPT = """\
You are the second reviewer in a 4-eye verification process for "lauschi",
a DACH children's audio player catalog.

A first AI has already curated this series (decided which albums from Spotify
and Apple Music to include/exclude) and reviewed its own work. Your job is
to independently verify those decisions.

## What you're checking

1. **Included albums**: Do these look like real episodes of this series?
   Albums may come from different providers (Spotify, Apple Music). The same
   episode on both providers is fine and expected.

2. **Excluded albums**: Were these correctly excluded? Real episodes should
   not be excluded. Valid exclusions: compilations, box sets, best-of,
   soundtracks, Lieder albums, karaoke, unrelated content.

3. **Overrides** (changes the first AI proposed): Do you agree with each?

4. **Splits** (proposed sub-series): Do these make sense?

## Your decision

- `approve: true` if sound overall. Minor issues OK.
- `approve: false` if significant problems: real episodes excluded, wrong
  content included, bad splits.
- Fill `concerns` with any issues, even if approving.
- For each override and split, state whether you agree.

## Rules

- Max 2 lookups (wikipedia), max 5 album detail checks.
- Do NOT propose new overrides or splits. Only verify existing ones.
- When in doubt, flag concerns but approve. False rejections are worse
  than letting minor issues through.
"""


def _build_verify_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, VerifyResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)
    agent: Agent[Deps, VerifyResult] = Agent(
        model,
        output_type=VerifyResult,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], provider_name: str, album_ids: list[str],
    ) -> list[dict]:
        """Get detailed album info from a specific provider. Max 5 IDs."""
        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return [{"error": f"Provider {provider_name} not available"}]
        results = []
        for aid in album_ids[:5]:
            album = target.album_details(aid)
            if album:
                results.append({
                    "id": album.id, "name": album.name, "provider": provider_name,
                    "total_tracks": album.total_tracks, "label": album.label,
                    "tracks": [{"name": t.name} for t in album.tracks[:10]],
                })
                console.print(f"  [dim]📀 {provider_name}:{aid[:8]}… → {album.name}[/]")
            else:
                results.append({"id": aid, "error": "not found"})
        return results

    @agent.tool
    def wikipedia_lookup(ctx: RunContext[Deps], query: str) -> str:
        """Look up German Wikipedia for factual context."""
        if ctx.deps._lookup_count >= ctx.deps._MAX_LOOKUPS:
            return "Lookup limit reached."
        ctx.deps._lookup_count += 1
        try:
            headers = {"User-Agent": "lauschi-catalog-verify/1.0"}
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={
                    "action": "query", "list": "search",
                    "srsearch": query, "srlimit": 3, "format": "json",
                },
                timeout=10,
            )
            r.raise_for_status()
            hits = r.json().get("query", {}).get("search", [])
            if not hits:
                return "No Wikipedia article found."
            title = hits[0]["title"]
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={
                    "action": "query", "titles": title,
                    "prop": "extracts", "exintro": False,
                    "explaintext": True, "exchars": 3000, "format": "json",
                },
                timeout=10,
            )
            pages = r.json().get("query", {}).get("pages", {})
            extract = next(iter(pages.values())).get("extract", "")
            console.print(f"  [dim]📖 wikipedia({query!r}) → {title}[/]")
            return f"Wikipedia: {title}\n\n{extract}"
        except Exception as e:
            return f"Wikipedia lookup failed: {e}"

    return agent


# ── Prompt builder ─────────────────────────────────────────────────────────

def _build_prompt(curation: dict) -> str:
    albums = curation.get("albums", [])
    review = curation.get("review", {})

    included = sorted(
        [a for a in albums if a.get("include")],
        key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
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
        lines.append(
            f"  ✅ [{a.get('provider', '?')}] {ep_str}{a['title']} [{a['album_id']}]",
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded[:30]:
        reason = a.get("exclude_reason", "")
        lines.append(
            f"  ❌ [{a.get('provider', '?')}] {a['title']} [{a['album_id']}]"
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

    notes = review.get("notes", "")
    if notes:
        lines.append(f"\n### First reviewer notes\n{notes[:1000]}")

    lines.append("\nReview the above. Spot-check if needed. Give your verdict.")
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

    # Check pipeline status
    review = curation.get("review", {})
    status = review.get("status")

    if not force:
        if status in ("approved", "ai_verified"):
            console.print(f"[dim]Skipping {series_id} (already {status})[/dim]")
            return None
        if status == "rejected":
            console.print(f"[dim]Skipping {series_id} (rejected)[/dim]")
            return None

    deps = Deps(providers=providers, series_id=series_id, curation=curation)
    agent = _build_verify_agent(model_name, api_key)
    prompt = _build_prompt(curation)

    for attempt in range(_MAX_RETRIES):
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
        except Exception as e:
            if attempt < _MAX_RETRIES - 1:
                console.print(f"[yellow]Attempt {attempt + 1} failed: {e}[/yellow]")
                await asyncio.sleep(_RETRY_DELAY)
            else:
                raise


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

    review["verification"] = {
        "model": model_name,
        "verified_at": datetime.now(tz=UTC).isoformat(),
        "approve": result.approve,
        "concerns": result.concerns,
        "override_verdicts": [v.model_dump() for v in result.override_verdicts],
        "split_verdicts": [v.model_dump() for v in result.split_verdicts],
    }

    disagreements = (
        [v for v in result.override_verdicts if not v.agree]
        + [v for v in result.split_verdicts if not v.agree]
    )

    if result.approve and not disagreements:
        action = "approved"
        review["status"] = "approved"
    else:
        action = "escalated"
        review["status"] = "escalated"

    if not dry_run:
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
        else:
            escalated += 1
            console.print(f"  [yellow]⚠ Escalated for human review[/yellow]")
            console.print(f"  Concerns: {result.concerns}")

    console.print(
        f"\n[bold]Results:[/bold] {approved} approved, {escalated} escalated, "
        f"{skipped} skipped, {failed} failed",
    )
    if dry_run:
        console.print("[dim]Dry run, no changes written.[/dim]")
