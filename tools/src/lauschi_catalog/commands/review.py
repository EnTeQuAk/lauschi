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
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import click
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.providers import CatalogProvider

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL = "kimi-k2.5"
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


def _effective_albums(curation: dict) -> list[dict]:
    """Get included albums, respecting existing review overrides."""
    review = curation.get("review", {})
    excludes = {o["album_id"] for o in review.get("overrides", []) if o["action"] == "exclude"}
    return [a for a in curation.get("albums", []) if a.get("include") and a["album_id"] not in excludes]


def _analyze_series(curation: dict) -> dict[str, Any]:
    """Pre-analyze a curation for the AI prompt."""
    albums = _effective_albums(curation)
    episodes = [a for a in albums if a.get("episode_num")]
    nums = sorted(a["episode_num"] for a in episodes)

    gaps = []
    if nums:
        for i in range(nums[0], nums[-1] + 1):
            if i not in nums:
                gaps.append(i)

    title_counter = Counter()
    for a in albums:
        words = re.sub(r"\d+|folge|teil|\(.*?\)", "", a["title"].lower()).split()
        for w in words:
            if len(w) > 3:
                title_counter[w] += 1

    providers = Counter(a.get("provider", "spotify") for a in albums)

    return {
        "total": len(albums),
        "with_episode_num": len(episodes),
        "episode_range": f"{nums[0]}-{nums[-1]}" if nums else "none",
        "gaps": gaps[:20],
        "providers": dict(providers),
        "common_words": title_counter.most_common(10),
    }


def _build_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, ReviewResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)

    agent: Agent[Deps, ReviewResult] = Agent(
        model,
        output_type=ReviewResult,
        system_prompt=(
            "You review curated Hörspiel series data for quality issues. "
            "Look for: sub-series mixed in, duplicate episodes across providers, "
            "gaps in episode numbering, era variants that should be split, "
            "and incorrect episode patterns. "
            "Propose overrides (exclude/include) and splits when needed. "
            "Be conservative; only flag clear issues."
        ),
        retries=2,
    )

    @agent.tool
    def show_series(ctx: RunContext[Deps]) -> dict:
        """Show the series curation data and analysis."""
        analysis = _analyze_series(ctx.deps.curation)
        albums = _effective_albums(ctx.deps.curation)
        return {
            "id": ctx.deps.curation.get("id"),
            "title": ctx.deps.curation.get("title"),
            "analysis": analysis,
            "sample_albums": [
                {
                    "title": a["title"],
                    "episode_num": a.get("episode_num"),
                    "provider": a.get("provider", "spotify"),
                    "album_id": a["album_id"],
                }
                for a in albums[:50]
            ],
        }

    @agent.tool
    def search_provider(
        ctx: RunContext[Deps], provider_name: str, query: str,
    ) -> list[dict]:
        """Search a provider for albums. Use to find missing episodes."""
        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return [{"error": f"Provider {provider_name} not available"}]
        albums = target.search_albums(query, limit=10)
        return [
            {"id": a.id, "name": a.name, "provider": provider_name, "total_tracks": a.total_tracks}
            for a in albums
        ]

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], provider_name: str, album_id: str,
    ) -> dict:
        """Get full album details from a provider."""
        key = f"{provider_name}:{album_id}"
        if key in ctx.deps.seen_details:
            return ctx.deps.seen_details[key]
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
        return result

    @agent.tool
    def add_album(
        ctx: RunContext[Deps], provider_name: str, album_id: str,
    ) -> str:
        """Add a missing album to the series. Searches the provider for details
        and extracts the episode number from the series pattern."""
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
        }
        ctx.deps.added_albums.append(new_album)
        ep_str = f" (episode {episode_num})" if episode_num else ""
        console.print(f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → {album.name}{ep_str}[/]")
        return f"Added: {album.name}{ep_str}"

    @agent.tool
    def update_episode_pattern(
        ctx: RunContext[Deps], patterns: list[str],
    ) -> str:
        """Update episode pattern(s). Each must have exactly 1 capture group.
        Patterns are tried in order. Also re-extracts episode numbers for
        existing albums."""
        import re as _re
        for p in patterns:
            try:
                c = _re.compile(p)
            except _re.error as e:
                return f"Invalid pattern {p!r}: {e}"
            if c.groups != 1:
                return f"Pattern {p!r}: need 1 capture group, got {c.groups}"

        new_pattern = patterns[0] if len(patterns) == 1 else patterns
        ctx.deps.curation["episode_pattern"] = new_pattern

        from lauschi_catalog.catalog.matcher import extract_episode
        updated = 0
        for album in ctx.deps.curation.get("albums", []):
            ep = extract_episode(new_pattern, album["title"])
            if ep is not None and album.get("episode_num") != ep:
                album["episode_num"] = ep
                updated += 1

        console.print(f"  [dim]📝 update_episode_pattern → {new_pattern} ({updated} re-extracted)[/]")
        return f"Updated pattern to {new_pattern}, re-extracted {updated} episodes"

    return agent


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

    analysis = _analyze_series(curation)
    title = curation.get("title", "?")

    prompt = (
        f"Review the curated series '{title}'.\n"
        f"Analysis: {json.dumps(analysis, indent=2)}\n\n"
        "Call show_series() to see the full data, then check for issues. "
        "Use search_provider and album_details if you need to verify gaps."
    )

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


def save_review(series_id: str, result: ReviewResult) -> Path:
    """Save review result into the curation JSON."""
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Curation file not found: {path}[/red]")
        raise SystemExit(1)

    data = json.loads(path.read_text())
    data["review"] = {
        "overrides": [o.model_dump() for o in result.overrides],
        "splits": [s.model_dump() for s in result.splits],
        "added_albums": [a.model_dump() for a in result.added_albums],
        "pattern_update": result.pattern_update,
        "notes": result.notes,
        "reviewed_at": datetime.now(UTC).isoformat(),
    }

    # Merge added albums into the main albums list
    if result.added_albums:
        existing_ids = {a["album_id"] for a in data.get("albums", [])}
        for added in result.added_albums:
            if added.album_id not in existing_ids:
                data.setdefault("albums", []).append(added.model_dump())

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Review all curated series")
@click.option("--model", default=_DEFAULT_MODEL)
@click.option("--timeout", default=300)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
def review(series_id: str | None, run_all: bool, model: str, timeout: int, provider: str):
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

    for path in paths:
        if not path.exists():
            console.print(f"[yellow]Skipping {path.stem}: no curation file[/yellow]")
            continue

        curation = json.loads(path.read_text())
        console.print(f"\n[bold]Reviewing {curation.get('title', path.stem)}...[/bold]")

        result = asyncio.run(
            _run_review(curation, providers, model_name=model, timeout=timeout),
        )

        if result.overrides or result.splits:
            save_path = save_review(path.stem, result)
            console.print(f"  {len(result.overrides)} overrides, {len(result.splits)} splits")
            console.print(f"  [green]Saved to {save_path}[/green]")
        else:
            console.print("  [dim]No issues found[/dim]")

        if result.notes:
            console.print(f"  Notes: {result.notes}")
