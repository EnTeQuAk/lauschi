#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai>=1.62.0",
#   "pydantic>=2.0",
#   "requests",
#   "diskcache",
#   "rich",
# ]
# ///
"""
curate-series.py — AI-assisted series curation for the lauschi catalog.

A pydantic-ai agent explores the Spotify API via tools, classifies every album,
and produces a validated CuratedSeries JSON.  Use review-curation.py to review
and write approved entries to series.yaml.

Usage
-----
  mise run catalog-curate -- "Sternenschweif"
  mise run catalog-curate -- "TKKG" --timeout 600
  mise run catalog-curate -- "Conni" --model claude-sonnet-4-6

Credentials
-----------
  SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET  — Spotify (in .env via mise)
  OPENCODE_API_KEY                           — opencode zen endpoint
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, field_validator
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
CURATION_DIR.mkdir(parents=True, exist_ok=True)

# Shared cached Spotify client (see spotify_cache.py)
sys.path.insert(0, str(Path(__file__).parent))
from spotify_cache import SpotifyClient  # noqa: E402

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL     = "kimi-k2.5"
_MAX_RETRIES       = 3
_RETRY_DELAY       = 5


# ── Pydantic output models ─────────────────────────────────────────────────────

class AlbumDecision(BaseModel):
    spotify_album_id: str
    include: bool
    episode_num: int | None = None
    title: str
    exclude_reason: str | None = None

    @field_validator("spotify_album_id")
    @classmethod
    def _valid_id(cls, v: str) -> str:
        if not re.match(r"^[A-Za-z0-9]{22}$", v):
            raise ValueError(f"Invalid Spotify album ID: {v!r}")
        return v


class CuratedSeries(BaseModel):
    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    keywords: list[str] = Field(default_factory=list)
    spotify_artist_ids: list[str]
    episode_pattern: str | None = None
    albums: list[AlbumDecision]
    age_note: str = Field(
        default="",
        description="Age guidance for the 3-14 range, e.g. 'Suitable from 3+' "
        "or 'Crime themes, recommended 8+'",
    )
    curator_notes: str = ""

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | None) -> str | None:
        if v is None:
            return None
        c = re.compile(v)
        if c.groups != 1:
            raise ValueError(f"Must have exactly 1 capture group, got {c.groups}")
        return v

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            key=lambda a: (a.episode_num or 999_999, a.title),
        )


# ── Agent ──────────────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are curating a DACH (Germany/Austria/Switzerland) children's Hörspiel series
catalog for "lauschi", a privacy-first kids audio player.

## Your job

Given a series name, use your tools to:
1. Search Spotify for the correct artist (one search is usually enough).
2. Fetch the full discography for the artist.
3. Classify every album: include (episode) or exclude (box set, duplicate, etc.).
4. For ambiguous albums, call get_album_details to check track count and names.

Do NOT search for "Junior", "Retro-Archiv", or other variant artists — those
are curated separately.  Focus only on the primary artist for this series.

## Include
Individual episodes: usually 1-5 tracks, 20-60 min.

## Exclude (with exclude_reason)
- Box sets / compilations ("Folge 1-10", "Jubiläumsbox", "Best of") — usually 10+ tracks
- Duplicate episodes: same number released twice; keep the most recent or unabridged
- Spinoff series from a different artist (note in curator_notes)
- Audiobooks, soundtracks, sing-alongs, podcast episodes
- Short stories / Kurzhörspiele (unless they have episode numbers in the main run)

## Episode numbers
Extract from: Folge N, Teil N, Episode N, Fall N, Band N, NNN/Title.
When prefixes change mid-run, use alternation: (?:[Tt]eil|[Bb]and)\\s+(\\d+)

## Keywords
Only if the series name literally appears in album titles. Otherwise leave empty.

## Age guidance
lauschi targets kids aged 3-14.  Most DACH Hörspiel series are fine for all ages.
Set age_note to a short guidance string based on your knowledge of the series:
- "Suitable from 3+" for gentle series (Benjamin Blümchen, Peppa Wutz)
- "Suitable from 5+" for series with mild tension (Fünf Freunde)
- "Recommended 8+" for series with crime, horror, or complex themes (Die drei ???, TKKG)
Only flag genuine concerns — don't over-rate harmless content.

## Important
- Produce an AlbumDecision for EVERY album in each artist's discography.
- spotify_album_id must exactly match the IDs returned by tools.
- Do NOT invent album IDs.
"""


@dataclass
class Deps:
    spotify: SpotifyClient
    no_cache: bool = False

    def __post_init__(self) -> None:
        # Track tool calls to short-circuit repeated requests within a run.
        # When kimi calls the same tool with the same args, return the cached
        # result immediately instead of hitting the API again.
        self.seen_searches: dict[str, list[dict]] = {}
        self.seen_albums: dict[str, list[dict]] = {}
        self.seen_details: dict[str, dict] = {}


def build_agent(model_name: str, api_key: str) -> Agent[Deps, CuratedSeries]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)
    agent: Agent[Deps, CuratedSeries] = Agent(
        model,
        output_type=CuratedSeries,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def search_artists(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search Spotify for artists. Returns id, name, followers, genres."""
        if query in ctx.deps.seen_searches:
            console.print(f"  [dim]🔍 search_artists({query!r}) → "
                          f"(cached, {len(ctx.deps.seen_searches[query])} results)[/]")
            return ctx.deps.seen_searches[query]
        results = ctx.deps.spotify.search_artists(query)
        ctx.deps.seen_searches[query] = results
        names = ", ".join(f"{a['name']} ({a['followers']:,})" for a in results[:5])
        console.print(f"  [dim]🔍 search_artists({query!r}) → {len(results)} "
                       f"results: {names}[/]")
        return results

    @agent.tool
    def get_artist_albums(ctx: RunContext[Deps], artist_id: str) -> list[dict]:
        """Fetch full discography for a Spotify artist.
        Returns list of {id, name, release_date, total_tracks}."""
        if artist_id in ctx.deps.seen_albums:
            console.print(f"  [dim]📀 get_artist_albums({artist_id[:8]}…) → "
                          f"(cached, {len(ctx.deps.seen_albums[artist_id])} albums)[/]")
            return ctx.deps.seen_albums[artist_id]
        albums = ctx.deps.spotify.artist_albums(artist_id,
                                                use_cache=not ctx.deps.no_cache)
        ctx.deps.seen_albums[artist_id] = albums
        console.print(f"  [dim]📀 get_artist_albums({artist_id[:8]}…) → "
                       f"{len(albums)} albums[/]")
        return albums

    @agent.tool
    def get_album_details(ctx: RunContext[Deps], album_id: str) -> dict:
        """Full album details: release_date, total_tracks, track names, label.
        Use for ambiguous albums — possible box sets or duplicates."""
        if album_id in ctx.deps.seen_details:
            console.print(f"  [dim]🔎 get_album_details({album_id[:8]}…) → "
                          f"(cached)[/]")
            return ctx.deps.seen_details[album_id]
        details = ctx.deps.spotify.album_details(album_id)
        ctx.deps.seen_details[album_id] = details
        name = details.get("name", "?")[:40]
        tracks = details.get("total_tracks", "?")
        console.print(f"  [dim]🔎 get_album_details({album_id[:8]}…) → "
                       f"{tracks} tracks — {name}[/]")
        return details

    return agent


# ── Run ────────────────────────────────────────────────────────────────────────

async def run_curation(model_name: str, api_key: str, query: str,
                       deps: Deps, timeout: int) -> CuratedSeries:
    agent = build_agent(model_name, api_key)
    prompt = (
        f"Curate the DACH Hörspiel series: {query!r}.\n\n"
        "Search for the primary Spotify artist, fetch their discography, then\n"
        "classify every album.  Do NOT search for Junior/Retro-Archiv variants."
    )

    last_err: Exception | None = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            result = await asyncio.wait_for(
                agent.run(
                    prompt, deps=deps,
                    usage_limits=UsageLimits(request_limit=200),
                ),
                timeout=timeout,
            )
            return result.output
        except asyncio.TimeoutError:
            raise TimeoutError(f"Timed out after {timeout}s") from None
        except Exception as e:
            last_err = e
            err_str = str(e)
            if ("<!DOCTYPE" in err_str or "500" in err_str) and attempt < _MAX_RETRIES:
                console.print(f"[yellow]Attempt {attempt}/{_MAX_RETRIES} failed "
                              f"(proxy error), retrying in {_RETRY_DELAY}s…[/]")
                await asyncio.sleep(_RETRY_DELAY)
                continue
            raise
    raise RuntimeError(f"Exhausted {_MAX_RETRIES} retries: {last_err}")


# ── Display ────────────────────────────────────────────────────────────────────

def print_summary(series: CuratedSeries) -> None:
    inc = series.included()
    exc = [x for x in series.albums if not x.include]
    eps = [a.episode_num for a in inc if a.episode_num is not None]

    from rich.markup import escape
    pattern = escape(series.episode_pattern or "(none)")
    console.print(Panel(
        f"[bold]{escape(series.title)}[/]  [dim]{series.id}[/]\n"
        f"Artists: {', '.join(series.spotify_artist_ids)}\n"
        f"Episodes: {len(inc)} included · {len(exc)} excluded\n"
        f"Range: {min(eps) if eps else '—'}–{max(eps) if eps else '—'}\n"
        f"Pattern: {pattern}",
        title="✅ Curated",
        border_style="green",
    ))

    if eps:
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        if gaps:
            console.print(f"[yellow]⚠ Gaps: {gaps[:20]}"
                          f"{'…' if len(gaps) > 20 else ''}[/]")

    t = Table(box=box.SIMPLE, title=f"Included (first 10 of {len(inc)})")
    t.add_column("Ep", width=5, justify="right")
    t.add_column("Title", min_width=40)
    t.add_column("ID", width=24)
    for ep in inc[:10]:
        t.add_row(str(ep.episode_num) if ep.episode_num else "—",
                  ep.title[:50], ep.spotify_album_id)
    if len(inc) > 10:
        t.add_row("…", f"({len(inc) - 10} more)", "")
    console.print(t)

    if series.age_note:
        console.print(f"\n👶 Age: {series.age_note}")

    if series.curator_notes:
        console.print(f"\n[dim]Notes: {escape(series.curator_notes[:200])}[/]")

    console.print(f"\n[dim]Review with: mise run catalog-review -- {series.id}[/]")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="AI-curated series curation via pydantic-ai + Spotify.",
        epilog='Example: mise run catalog-curate -- "Sternenschweif"',
    )
    ap.add_argument("query", help="Series name to curate")
    ap.add_argument("--model", default=_DEFAULT_MODEL,
                    help=f"opencode model (default: {_DEFAULT_MODEL})")
    ap.add_argument("--no-cache", action="store_true",
                    help="Bypass Spotify cache")
    ap.add_argument("--timeout", type=int, default=1800,
                    help="Timeout in seconds (default: 1800)")
    args = ap.parse_args()

    api_key = os.environ.get("OPENCODE_API_KEY")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set — add to .env[/]")
        sys.exit(1)

    spotify = SpotifyClient()
    deps = Deps(spotify=spotify, no_cache=args.no_cache)

    console.print(Panel(
        f"[bold]{args.query}[/]\n"
        f"Model: {args.model} · Timeout: {args.timeout}s",
        title="🎧 lauschi series curator",
    ))

    try:
        series = asyncio.run(
            run_curation(args.model, api_key, args.query, deps, args.timeout)
        )
    except Exception as e:
        console.print(f"[red]Failed:[/] {e}")
        sys.exit(1)

    print_summary(series)

    # Save curation JSON
    curation_path = CURATION_DIR / f"{series.id}.json"
    curation_path.write_text(
        json.dumps({
            "query": args.query,
            "model": args.model,
            "curated_at": datetime.now(tz=UTC).isoformat(),
            "series": series.model_dump(),
        }, indent=2, ensure_ascii=False),
    )
    console.print(f"Saved → {curation_path.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
