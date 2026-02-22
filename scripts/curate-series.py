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

For small discographies (≤100 albums), a single agent call handles everything.

For large discographies, albums are processed in batches of ~30.  Each batch
gets series context + album metadata, and kimi can call get_album_details for
anything ambiguous.  Fresh context per batch keeps things fast and reliable.

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
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

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

# Discographies above this threshold use the batched flow.
_LARGE_DISCOGRAPHY_THRESHOLD = 100
_BATCH_SIZE = 30


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
    episode_pattern: str | list[str] | None = None
    albums: list[AlbumDecision]
    age_note: str = Field(
        default="",
        description="Age guidance for the 3-14 range, e.g. 'Suitable from 3+' "
        "or 'Crime themes, recommended 8+'",
    )
    curator_notes: str = ""

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups != 1:
                raise ValueError(
                    f"Pattern {p!r}: must have exactly 1 capture group, got {c.groups}",
                )
        return v

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            key=lambda a: (a.episode_num or 999_999, a.title),
        )


# ── Batch output model ────────────────────────────────────────────────────────

class BatchResult(BaseModel):
    """Decisions for one batch of albums."""
    albums: list[AlbumDecision]


# ── Series metadata model ─────────────────────────────────────────────────────

class SeriesMetadata(BaseModel):
    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    keywords: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = None
    age_note: str = ""
    curator_notes: str = ""

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups != 1:
                raise ValueError(
                    f"Pattern {p!r}: must have exactly 1 capture group, got {c.groups}",
                )
        return v


# ══════════════════════════════════════════════════════════════════════════════
#  SMALL DISCOGRAPHY — single agent (original flow, unchanged)
# ══════════════════════════════════════════════════════════════════════════════

_SYSTEM_PROMPT = """\
You are curating a DACH (Germany/Austria/Switzerland) children's Hörspiel series
catalog for "lauschi", a privacy-first kids audio player.

## Your job

Given a series name, use your tools to:
1. Search Spotify for the correct artist (one search is usually enough).
2. Fetch the full discography for the artist.
3. Classify every album: include (episode) or exclude (box set, duplicate, etc.).
4. For ambiguous albums, call get_album_details with multiple IDs at once (batching saves time).

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
        albums = ctx.deps.spotify.artist_albums(artist_id)
        ctx.deps.seen_albums[artist_id] = albums
        console.print(f"  [dim]📀 get_artist_albums({artist_id[:8]}…) → "
                       f"{len(albums)} albums[/]")
        return albums

    @agent.tool
    def get_album_details(
        ctx: RunContext[Deps], album_ids: list[str],
    ) -> list[dict]:
        """Full album details: release_date, total_tracks, track names, label.
        Use for ambiguous albums — possible box sets or duplicates.
        Pass multiple IDs at once to save time."""
        results = []
        for album_id in album_ids:
            if album_id in ctx.deps.seen_details:
                console.print(f"  [dim]🔎 get_album_details({album_id[:8]}…) → "
                              f"(cached)[/]")
                results.append(ctx.deps.seen_details[album_id])
                continue
            details = ctx.deps.spotify.album_details(album_id)
            ctx.deps.seen_details[album_id] = details
            name = details.get("name", "?")[:40]
            tracks = details.get("total_tracks", "?")
            console.print(f"  [dim]🔎 get_album_details({album_id[:8]}…) → "
                           f"{tracks} tracks — {name}[/]")
            results.append(details)
        return results

    return agent


async def run_small(model_name: str, api_key: str, query: str,
                    deps: Deps, timeout: int) -> CuratedSeries:
    """Single-agent flow for small discographies."""
    agent = build_agent(model_name, api_key)
    prompt = (
        f"Curate the DACH Hörspiel series: {query!r}.\n\n"
        "Search for the primary Spotify artist, fetch their discography, then\n"
        "classify every album.  Do NOT search for Junior/Retro-Archiv variants."
    )
    return await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(agent, prompt, deps), timeout=timeout,
        ),
        phase="curation",
    )


# ══════════════════════════════════════════════════════════════════════════════
#  LARGE DISCOGRAPHY — batched processing
# ══════════════════════════════════════════════════════════════════════════════

_METADATA_SYSTEM_PROMPT = """\
You are setting up metadata for a DACH children's Hörspiel series catalog entry.

Given a series name and a sample of album titles from its Spotify discography,
provide:
- id: lowercase snake_case identifier (e.g., "paw_patrol", "die_drei_fragezeichen")
- title: display name (e.g., "PAW Patrol", "Die drei ???")
- aliases: alternate names the series goes by (e.g., different languages)
- keywords: only if the series name literally appears in album titles
- episode_pattern: regex (or list of regexes) with exactly 1 capture group each
  for the episode number. Use a list when a series changed naming conventions,
  e.g. ["^(\\d{3})/", "^Folge (\\d+):"] — tried in order, first match wins.
- age_note: "Suitable from 3+", "Suitable from 5+", or "Recommended 8+"
- curator_notes: anything noteworthy (spinoffs, format changes, etc.)

No tools needed — just your knowledge of DACH Hörspiel series.
"""

_BATCH_SYSTEM_PROMPT = """\
You are curating a batch of albums for a DACH children's Hörspiel series.

You receive:
- Series context (title, episode pattern, what's been decided so far)
- A batch of albums with: spotify_album_id, title, total_tracks, release_date

For each album, decide: include or exclude.

## Include — individual episodes
- Title matches episode pattern (e.g., "Folge NNN: …")
- Typical episode track count (2-8 tracks)
- Extract episode_num when possible

## Exclude (set exclude_reason)
- Compilations / box sets (10+ tracks, "Folge 1-10", "Best of")
- Foreign language releases (Polish, Spanish, etc.)
- Single music tracks (1 track, not a Hörspiel)
- Multi-artist compilations ("Kinderparty Hits", "Nick Jr.'s …")
- Remixes, sped-up versions, sing-alongs, soundtracks
- Duplicates of already-included episodes

## When unsure
Call get_album_details to see the track listing — that usually resolves it.
Only fetch details for albums where the title + track count is genuinely
ambiguous.  Most episodes are obvious from the title alone.

## Important
- Produce an AlbumDecision for EVERY album in this batch.
- spotify_album_id must EXACTLY match the IDs provided.
- Do NOT invent album IDs.
"""


@dataclass
class BatchDeps:
    spotify: SpotifyClient
    seen_details: dict[str, dict] = field(default_factory=dict)


def _build_batch_agent(
    model: OpenAIChatModel,
) -> Agent[BatchDeps, BatchResult]:
    agent: Agent[BatchDeps, BatchResult] = Agent(
        model,
        output_type=BatchResult,
        system_prompt=_BATCH_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def get_album_details(
        ctx: RunContext[BatchDeps], album_ids: list[str],
    ) -> list[dict]:
        """Full album details: track names, label, release date.
        Call this for ambiguous albums where title + track count isn't enough."""
        results = []
        for album_id in album_ids:
            if album_id in ctx.deps.seen_details:
                console.print(f"  [dim]🔎 {album_id[:8]}… → (cached)[/]")
                results.append(ctx.deps.seen_details[album_id])
                continue
            details = ctx.deps.spotify.album_details(album_id)
            ctx.deps.seen_details[album_id] = details
            name = details.get("name", "?")[:40]
            tracks = details.get("total_tracks", "?")
            console.print(f"  [dim]🔎 {album_id[:8]}… → {tracks} tracks — {name}[/]")
            results.append(details)
        return results

    return agent


async def run_large(
    model_name: str, api_key: str, query: str,
    spotify: SpotifyClient, timeout: int,
) -> CuratedSeries:
    """Batched flow for large discographies."""
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)

    # ── Discovery: find artist + fetch discography ─────────────────────────
    console.print("\n[bold cyan]Discovery[/]\n")

    artists = spotify.search_artists(query)
    if not artists:
        raise ValueError(f"No Spotify artist found for {query!r}")

    artist = artists[0]
    artist_id = artist["id"]
    console.print(f"  Artist: [bold]{artist['name']}[/] "
                  f"({artist['followers']:,} followers) [{artist_id}]")

    albums = spotify.artist_albums(artist_id)
    console.print(f"  Albums: {len(albums)}\n")

    # ── Metadata: series info (no tools, tiny call) ────────────────────────
    console.print("[bold cyan]Metadata[/]\n")

    sample_titles = [a["name"] for a in albums[:30]]
    metadata_agent: Agent[None, SeriesMetadata] = Agent(
        model, output_type=SeriesMetadata,
        system_prompt=_METADATA_SYSTEM_PROMPT, retries=2,
    )
    meta: SeriesMetadata = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(metadata_agent,
                       f"Series: {query!r}\nSample titles:\n" +
                       "\n".join(f"  - {t}" for t in sample_titles),
                       deps=None),
            timeout=120,
        ),
        phase="metadata",
    )
    console.print(f"  id={meta.id}  title={meta.title!r}  "
                  f"pattern={meta.episode_pattern}  age={meta.age_note}\n")

    # ── Batched curation ───────────────────────────────────────────────────
    batches = [albums[i:i + _BATCH_SIZE]
               for i in range(0, len(albums), _BATCH_SIZE)]

    console.print(f"[bold cyan]Curation[/] — {len(albums)} albums in "
                  f"{len(batches)} batches of ≤{_BATCH_SIZE}\n")

    batch_agent = _build_batch_agent(model)
    all_decisions: list[AlbumDecision] = []
    total_inc = 0
    total_exc = 0
    episode_nums: list[int] = []

    for batch_num, batch in enumerate(batches, 1):
        # Build compact progress context
        if episode_nums:
            progress = (f"Progress so far: {total_inc} included (episodes "
                        f"{min(episode_nums)}–{max(episode_nums)}), "
                        f"{total_exc} excluded.")
        else:
            progress = f"Progress so far: {total_inc} included, {total_exc} excluded."

        album_lines = "\n".join(
            f"  {a['id']} | {a['name']} | {a['total_tracks']} tracks | {a['release_date']}"
            for a in batch
        )
        prompt = (
            f"Series: {meta.title!r}\n"
            f"Episode pattern: {meta.episode_pattern}\n"
            f"{progress}\n\n"
            f"Batch {batch_num}/{len(batches)} ({len(batch)} albums):\n\n"
            f"{album_lines}"
        )

        batch_deps = BatchDeps(spotify=spotify)
        result: BatchResult = await _run_with_retry(
            # Capture prompt and deps by value via default args.
            lambda p=prompt, d=batch_deps: asyncio.wait_for(
                _run_agent(batch_agent, p, d), timeout=300,
            ),
            phase=f"batch {batch_num}/{len(batches)}",
        )

        n_inc = sum(1 for a in result.albums if a.include)
        n_exc = sum(1 for a in result.albums if not a.include)
        total_inc += n_inc
        total_exc += n_exc
        for a in result.albums:
            if a.include and a.episode_num is not None:
                episode_nums.append(a.episode_num)

        console.print(f"  Batch {batch_num}/{len(batches)}: "
                      f"[green]+{n_inc}[/] [red]-{n_exc}[/]  "
                      f"(total: {total_inc} included, {total_exc} excluded)")

        all_decisions.extend(result.albums)

    console.print(f"\n  [bold]Total: [green]{total_inc} included[/]  "
                  f"[red]{total_exc} excluded[/][/]\n")

    # ── Assemble final CuratedSeries ───────────────────────────────────────
    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        keywords=meta.keywords,
        spotify_artist_ids=[artist_id],
        episode_pattern=meta.episode_pattern,
        albums=all_decisions,
        age_note=meta.age_note,
        curator_notes=meta.curator_notes,
    )


# ══════════════════════════════════════════════════════════════════════════════
#  Shared helpers
# ══════════════════════════════════════════════════════════════════════════════

async def _run_agent(agent: Agent, prompt: str, deps: object) -> object:
    """Run an agent and return its output."""
    result = await agent.run(
        prompt, deps=deps,
        usage_limits=UsageLimits(request_limit=200),
    )
    return result.output


async def _run_with_retry(
    coro_factory, *, max_retries: int = _MAX_RETRIES, phase: str = "",
) -> object:
    """Run an async coroutine with retry on proxy 500 errors."""
    last_err: Exception | None = None
    for attempt in range(1, max_retries + 1):
        try:
            return await coro_factory()
        except asyncio.TimeoutError:
            raise
        except Exception as e:
            last_err = e
            err_str = str(e)
            console.print(f"[dim red]{type(e).__name__}: {err_str[:500]}[/]")
            body = getattr(e, "body", None)
            if body is not None:
                console.print(f"[dim red]body: {body}[/]")
            if ("<!DOCTYPE" in err_str or "500" in err_str) and attempt < max_retries:
                console.print(f"[yellow]{phase}: attempt {attempt}/{max_retries} "
                              f"failed (proxy error), retrying in {_RETRY_DELAY}s…[/]")
                await asyncio.sleep(_RETRY_DELAY)
                continue
            raise
    raise RuntimeError(f"Exhausted {max_retries} retries in {phase}: {last_err}")


# ── Run dispatcher ─────────────────────────────────────────────────────────────

async def run_curation(
    model_name: str, api_key: str, query: str,
    spotify: SpotifyClient, timeout: int,
) -> CuratedSeries:
    """Pick single-agent or batched flow based on discography size."""
    artists = spotify.search_artists(query)
    if not artists:
        raise ValueError(f"No Spotify artist found for {query!r}")

    albums = spotify.artist_albums(artists[0]["id"])

    if len(albums) <= _LARGE_DISCOGRAPHY_THRESHOLD:
        console.print(f"  {len(albums)} albums — using [bold]single-agent[/] flow\n")
        deps = Deps(spotify=spotify)
        return await run_small(model_name, api_key, query, deps, timeout)

    console.print(f"  {len(albums)} albums — using [bold]batched[/] flow\n")
    return await run_large(model_name, api_key, query, spotify, timeout)


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

    console.print(Panel(
        f"[bold]{args.query}[/]\n"
        f"Model: {args.model} · Timeout: {args.timeout}s",
        title="🎧 lauschi series curator",
    ))

    try:
        series = asyncio.run(
            run_curation(args.model, api_key, args.query, spotify, args.timeout)
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
