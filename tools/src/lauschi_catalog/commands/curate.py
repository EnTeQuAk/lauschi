"""AI-assisted series curation across providers.

Uses pydantic-ai to analyze discographies from all configured providers,
decide which albums belong to the series, and extract episode numbers.

For small discographies (≤100 albums total), a single agent call handles it.
For large ones, albums are processed in batches of ~30. Each batch gets
series context + album metadata, and the AI can call get_album_details for
anything ambiguous. Fresh context per batch keeps things fast and reliable.

Ported from scripts/curate-series.py with multi-provider support.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import click
from pydantic import BaseModel, Field, field_validator
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.providers import Album, CatalogProvider

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
CURATION_DIR.mkdir(parents=True, exist_ok=True)

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL = "kimi-k2.5"
_MAX_RETRIES = 3
_RETRY_DELAY = 5

# Discographies above this threshold use the batched flow.
_LARGE_THRESHOLD = 100
_BATCH_SIZE = 30


# ── Output models ──────────────────────────────────────────────────────────

class AlbumDecision(BaseModel):
    """Decision for a single album from any provider."""

    album_id: str
    provider: str  # "spotify" or "apple_music"
    include: bool
    episode_num: int | None = None
    title: str
    exclude_reason: str | None = None


class CuratedSeries(BaseModel):
    """Complete curation result for a series or music artist."""

    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    keywords: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = None
    albums: list[AlbumDecision]
    provider_artist_ids: dict[str, list[str]] = Field(default_factory=dict)
    age_note: str = ""
    curator_notes: str = ""
    # Content type: "hoerspiel" (default) or "music". Persisted in the
    # curation JSON so re-curation picks the right AI prompt.
    content_type: str = "hoerspiel"

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups < 1:
                msg = f"Pattern {p!r}: needs at least 1 capture group"
                raise ValueError(msg)
        return v

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            key=lambda a: (a.episode_num or 999_999, a.title),
        )

    def by_provider(self, provider: str) -> list[AlbumDecision]:
        return [a for a in self.included() if a.provider == provider]


class BatchResult(BaseModel):
    """Decisions for one batch of albums."""
    albums: list[AlbumDecision]


class SeriesMetadata(BaseModel):
    """Metadata extracted in the first phase (no album decisions)."""
    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    keywords: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = None
    age_note: str = ""
    curator_notes: str = ""
    provider_artist_ids: dict[str, list[str]] = Field(default_factory=dict)

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups < 1:
                msg = f"Pattern {p!r}: needs at least 1 capture group"
                raise ValueError(msg)
        return v


# ── Agent dependencies ─────────────────────────────────────────────────────

@dataclass
class Deps:
    providers: list[CatalogProvider]
    seen_albums: dict[str, list[dict]] = field(default_factory=dict)
    seen_details: dict[str, dict] = field(default_factory=dict)
    _search_count: int = field(default=0, init=False)
    _MAX_SEARCHES: int = 2


@dataclass
class BatchDeps:
    providers: list[CatalogProvider]
    seen_details: dict[str, dict] = field(default_factory=dict)


# ── System prompts ─────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are curating a DACH (Germany/Austria/Switzerland) children's Hörspiel series
catalog for "lauschi", a privacy-first kids audio player.

## Your job

Given a series name, use your tools to:
1. Search for the correct artist on EACH available provider (Spotify, Apple Music).
2. Fetch the full discography from each provider.
3. Classify every album: include (episode) or exclude (box set, duplicate, etc.).
4. For ambiguous albums, call get_album_details with multiple IDs at once (batching saves time).

Albums from different providers representing the same episode should BOTH be
included. Each gets its own AlbumDecision with the correct provider tag.

Do NOT search for "Junior", "Retro-Archiv", or other variant artists — those
are curated separately. Focus only on the primary artist for this series.

## Include
Individual episodes: usually 1-5 tracks, 20-60 min.

## Exclude (with exclude_reason)
- Box sets / compilations ("Folge 1-10", "Jubiläumsbox", "Best of") — usually 10+ tracks
- Duplicate episodes: same number released twice; keep the most recent or unabridged
- Spinoff series from a different artist (note in curator_notes)
- Audiobooks ("ungekürzt"), soundtracks, sing-alongs, podcast episodes
- Short stories / Kurzhörspiele (unless they have episode numbers in the main run)
- Foreign language releases (Polish, Spanish, etc.) unless the series is bilingual
- Single music tracks (1 track, not a Hörspiel)
- Sped-up / nightcore versions, karaoke, instrumental arrangements

## Episode numbers
Extract from: Folge N, Teil N, Episode N, Fall N, Band N, NNN/Title.
When prefixes change mid-run, use alternation: (?:[Tt]eil|[Bb]and)\\s+(\\d+)

## Keywords
Only if the series name literally appears in album titles. Otherwise leave empty.

## Age guidance
lauschi targets kids aged 3-14. Set age_note based on your knowledge:
- "Suitable from 3+" for gentle series (Benjamin Blümchen, Peppa Wutz)
- "Suitable from 5+" for series with mild tension (Fünf Freunde)
- "Recommended 8+" for crime, horror, or complex themes (Die drei ???, TKKG)

## provider_artist_ids
Return a dict mapping provider name to artist ID list:
{"spotify": ["abc123"], "apple_music": ["456789"]}

## Web search
You have a web_search tool (max 2 searches). Use it when:
- You're unsure whether a series is a Hörspiel or Hörbuch/music
- The artist search returns ambiguous results (multiple artists, wrong genre)
- You need to confirm how many episodes a series actually has

Good queries:
- `"Series Name" Hörspiel Episodenliste` for episode info
- `site:hoerspiele.de "Series Name"` for the authoritative German Hörspiel database
- `"Series Name" Hörspiel OR Hörbuch` to clarify format

Don't search for well-known series (TKKG, Die drei ???, Benjamin Blümchen) where
the album metadata is unambiguous.

## Important
- Produce an AlbumDecision for EVERY album in each artist's discography.
- album_id must exactly match the IDs returned by tools.
- provider must match the provider that returned the album.
- Do NOT invent album IDs.
"""

_METADATA_SYSTEM_PROMPT = """\
You are setting up metadata for a DACH children's Hörspiel series catalog entry.

Given a series name and a sample of album titles from its discography across
multiple providers, provide:
- id: lowercase snake_case identifier (e.g., "paw_patrol", "die_drei_fragezeichen")
- title: display name (e.g., "PAW Patrol", "Die drei ???")
- aliases: alternate names the series goes by (different languages, abbreviations)
- keywords: only if the series name literally appears in album titles
- episode_pattern: regex (or list of regexes) with exactly 1 capture group each
  for the episode number. Use a list when a series changed naming conventions,
  e.g. ["^(\\d{3})/", "^Folge (\\d+):"] — tried in order, first match wins.
- age_note: "Suitable from 3+", "Suitable from 5+", or "Recommended 8+"
- curator_notes: anything noteworthy (spinoffs, format changes, etc.)
- provider_artist_ids: {provider: [artist_ids]} for each provider found

Do NOT classify individual albums. Just set up the metadata.
"""

_MUSIC_SYSTEM_PROMPT = """\
You are curating a DACH (Germany/Austria/Switzerland) children's MUSIC artist
catalog for "lauschi", a privacy-first kids audio player.

## Your job

Given a music artist name, use your tools to:
1. Search for the correct artist on EACH available provider (Spotify, Apple Music).
2. Fetch the full discography from each provider.
3. Classify every album: include (kids music) or exclude (not suitable).
4. For ambiguous albums, call get_album_details with multiple IDs at once.

This is a MUSIC artist (Kinderlieder, Kinderpop), NOT a Hörspiel series.
Albums are standalone music releases, not numbered episodes.

## Include
- Original studio albums of children's music / Kinderlieder
- EPs and singles by the artist
- Live albums of kids content
- Seasonal albums (Weihnachtslieder, Laternenlieder) by the artist
- Collaboration albums where the artist is the primary act

## Exclude (with exclude_reason)
- "Best Of" / "Greatest Hits" compilations (keep originals, skip compilations)
- Multi-artist compilations where the artist is just one contributor
- Duplicate releases (deluxe edition if standard exists, remastered if original exists)
- Sped-up / nightcore / karaoke / instrumental versions
- Adult/non-kids content by the same artist (if they also make adult music)
- Audiobooks / Hörspiele (different content type, curated separately)
- Foreign language versions unless the artist is multilingual by nature

## Episode numbers
Music albums don't have episode numbers. Set episode_num to null for all.

## Keywords
The artist name, plus any well-known album or song titles that parents
might search for (e.g., "Hoch die Hände" for Senta).

## Age guidance
- "Suitable from 2+" for lullabies, baby music (Schlaflieder)
- "Suitable from 3+" for general Kinderlieder (Detlev Jöcker, Simone Sommerland)
- "Suitable from 5+" for Kinderpop with more energy (Deine Freunde, DIKKA)
- "Suitable from 6+" for rock/loud content (Heavysaurus)

## provider_artist_ids
Return a dict mapping provider name to artist ID list.

## Web search
Use web_search when unsure if the artist makes kids-appropriate content,
or to check if a specific album is a compilation vs original release.

## Important
- Produce an AlbumDecision for EVERY album.
- album_id must exactly match the IDs returned by tools.
- provider must match the provider that returned the album.
- Do NOT invent album IDs.
"""

_MUSIC_BATCH_SYSTEM_PROMPT = """\
You are curating a batch of albums for a DACH children's music artist.

This is a MUSIC artist (Kinderlieder, Kinderpop), NOT a Hörspiel series.
All albums are music releases. There are no episode numbers.

You receive:
- Artist context (name, what's been decided so far)
- A batch of albums with: provider, album_id, title, total_tracks, release_date

For each album, decide: include or exclude.

## Include — original music releases
- Studio albums, EPs, singles of children's music
- Seasonal releases (Weihnachtslieder, Laternenlieder)
- Albums from different providers for the same release: include BOTH

## Exclude (set exclude_reason)
- "Best Of" / "Greatest Hits" compilations
- Multi-artist compilations ("Kinderparty Hits", "Die 30 besten...")
- Duplicate releases (deluxe vs standard, remastered vs original: keep one)
- Sped-up, nightcore, karaoke, instrumental versions
- Adult/non-kids content
- Hörspiele / audiobooks (curated separately)

## Episode numbers
Set episode_num to null for ALL albums. Music albums are not episodes.

## When unsure
Call get_album_details to see the track listing.

## Important
- Produce an AlbumDecision for EVERY album in this batch.
- album_id must EXACTLY match the IDs provided.
- provider must EXACTLY match the provider provided.
"""

_BATCH_SYSTEM_PROMPT = """\
You are curating a batch of albums for a DACH children's Hörspiel series.

You receive:
- Series context (title, episode pattern, what's been decided so far)
- A batch of albums with: provider, album_id, title, total_tracks, release_date

For each album, decide: include or exclude.

## Include — individual episodes
- Title matches episode pattern (e.g., "Folge NNN: …")
- Typical episode track count (2-8 tracks)
- Extract episode_num when possible
- Albums from different providers for the same episode: include BOTH

## Exclude (set exclude_reason)
- Compilations / box sets (10+ tracks, "Folge 1-10", "Best of")
- Foreign language releases (Polish, Spanish, etc.)
- Single music tracks (1 track, not a Hörspiel)
- Multi-artist compilations ("Kinderparty Hits", "Nick Jr.'s …")
- Remixes, sped-up versions, sing-alongs, soundtracks
- Audiobooks ("ungekürzt") that are book readings, not radio dramas
- Duplicates of already-included episodes (same episode number, same provider)

## When unsure
Call get_album_details to see the track listing — that usually resolves it.
Only fetch details for albums where the title + track count is genuinely
ambiguous. Most episodes are obvious from the title alone.

## Important
- Produce an AlbumDecision for EVERY album in this batch.
- album_id must EXACTLY match the IDs provided.
- provider must EXACTLY match the provider provided.
- Do NOT invent album IDs.
"""


# ── Agent builders ─────────────────────────────────────────────────────────

def _build_small_agent(
    model_name: str, api_key: str, *, is_music: bool = False,
) -> Agent[Deps, CuratedSeries]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)
    prompt = _MUSIC_SYSTEM_PROMPT if is_music else _SYSTEM_PROMPT
    agent: Agent[Deps, CuratedSeries] = Agent(
        model,
        output_type=CuratedSeries,
        system_prompt=prompt,
        retries=2,
    )

    @agent.tool
    def search_artists(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search all providers for artists."""
        results = []
        for p in ctx.deps.providers:
            for artist in p.search_artists(query):
                results.append({
                    "provider": p.name, "id": artist.id,
                    "name": artist.name, "genres": artist.genres,
                })
        console.print(f"  [dim]🔍 search_artists({query!r}) → {len(results)} results[/]")
        return results

    @agent.tool
    def get_artist_albums(
        ctx: RunContext[Deps], provider: str, artist_id: str,
    ) -> list[dict]:
        """Fetch full discography for an artist on a specific provider."""
        key = f"{provider}:{artist_id}"
        if key in ctx.deps.seen_albums:
            n = len(ctx.deps.seen_albums[key])
            console.print(f"  [dim]📀 get_artist_albums({provider}, {artist_id[:8]}…) → (cached, {n} albums)[/]")
            return ctx.deps.seen_albums[key]
        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return []
        albums = target.artist_albums(artist_id)
        result = [
            {"provider": provider, "id": a.id, "name": a.name,
             "release_date": a.release_date, "total_tracks": a.total_tracks}
            for a in albums
        ]
        ctx.deps.seen_albums[key] = result
        console.print(f"  [dim]📀 get_artist_albums({provider}, {artist_id[:8]}…) → {len(result)} albums[/]")
        return result

    @agent.tool
    def get_album_details(
        ctx: RunContext[Deps], provider: str, album_ids: list[str],
    ) -> list[dict]:
        """Full album details from a provider. Batch multiple IDs."""
        results = []
        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return []
        for aid in album_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider, "id": album.id, "name": album.name,
                    "total_tracks": album.total_tracks, "label": album.label,
                    "tracks": [{"name": t.name, "duration_ms": t.duration_ms}
                               for t in album.tracks],
                }
                ctx.deps.seen_details[key] = detail
                results.append(detail)
                console.print(f"  [dim]🔎 {provider}:{aid[:8]}… → {album.total_tracks} tracks[/]")
        return results

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search the web for series info. Max 2 searches.

        Use when unsure about a series (Hörspiel vs Hörbuch, correct artist,
        episode count). Good queries:
        - '"Series Name" Hörspiel Episodenliste'
        - 'site:hoerspiele.de "Series Name"'
        """
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            return [{"error": "Search limit reached (max 2)."}]
        ctx.deps._search_count += 1

        from lauschi_catalog.search import brave_search

        results = brave_search(query, count=5)
        n = len([r for r in results if "error" not in r])
        console.print(f"  [dim]🌐 web_search({query!r}) → {n} results[/]")
        return results

    return agent


def _build_batch_agent(model, *, is_music: bool = False) -> Agent[BatchDeps, BatchResult]:
    """Agent for processing one batch of albums."""
    prompt = _MUSIC_BATCH_SYSTEM_PROMPT if is_music else _BATCH_SYSTEM_PROMPT
    agent: Agent[BatchDeps, BatchResult] = Agent(
        model,
        output_type=BatchResult,
        system_prompt=prompt,
        retries=2,
    )

    @agent.tool
    def get_album_details(
        ctx: RunContext[BatchDeps], provider: str, album_ids: list[str],
    ) -> list[dict]:
        """Get album details for ambiguous albums."""
        results = []
        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return []
        for aid in album_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                console.print(f"  [dim]🔎 {provider}:{aid[:8]}… → (cached)[/]")
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider, "id": album.id, "name": album.name,
                    "total_tracks": album.total_tracks, "label": album.label,
                    "tracks": [{"name": t.name, "duration_ms": t.duration_ms}
                               for t in album.tracks[:10]],
                }
                ctx.deps.seen_details[key] = detail
                name = album.name[:40]
                console.print(f"  [dim]🔎 {provider}:{aid[:8]}… → {album.total_tracks} tracks — {name}[/]")
                results.append(detail)
        return results

    return agent


# ── Shared helpers ─────────────────────────────────────────────────────────

async def _run_agent(agent, prompt, deps):
    """Run an agent with streaming reasoning output."""
    async with agent.iter(
        prompt, deps=deps,
        usage_limits=UsageLimits(request_limit=200),
    ) as run:
        async for node in run:
            # Show AI reasoning as it streams in.
            if not hasattr(node, "model_response"):
                continue
            for part in node.model_response.parts:
                text = getattr(part, "content", None)
                if not isinstance(text, str) or len(text.strip()) <= 80:
                    continue
                kind = getattr(part, "part_kind", "")
                if kind == "thinking":
                    # Show thinking in a dim panel
                    console.print(
                        Panel(
                            text.strip()[:500],
                            border_style="dim",
                            title="💭 reasoning",
                            padding=(0, 1),
                        ),
                    )
        return run.result.output


async def _run_with_retry(coro_factory, *, phase: str = ""):
    import traceback as _tb

    last_err: Exception | None = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            return await coro_factory()
        except asyncio.TimeoutError:
            raise
        except Exception as e:
            last_err = e
            err_str = str(e)
            tb_str = _tb.format_exc()
            console.print(f"[dim red]{tb_str[:1000]}[/]")
            if ("<!DOCTYPE" in err_str or "500" in err_str) and attempt < _MAX_RETRIES:
                console.print(
                    f"[yellow]{phase} attempt {attempt}/{_MAX_RETRIES} "
                    f"failed, retrying in {_RETRY_DELAY}s…[/]",
                )
                await asyncio.sleep(_RETRY_DELAY)
                continue
            raise
    raise RuntimeError(f"Exhausted {_MAX_RETRIES} retries in {phase}: {last_err}")


# ── Small discography flow (single agent) ──────────────────────────────────

async def _run_small(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str,
    api_key: str,
    timeout: int,
    existing_curation: dict | None = None,
    is_music: bool = False,
) -> CuratedSeries:
    agent = _build_small_agent(model_name, api_key, is_music=is_music)
    deps = Deps(providers=providers)
    provider_names = ", ".join(p.name for p in providers)

    content_type = "children's music artist" if is_music else "Hörspiel series"
    prompt = (
        f"Curate the DACH {content_type}: {query!r}.\n\n"
        f"Available providers: {provider_names}.\n"
        "Search for the primary artist on EACH provider, fetch their "
        "discography, then classify every album."
    )

    if existing_curation:
        prev = existing_curation.get("albums", [])
        prev_inc = [a for a in prev if a.get("include")]
        prompt += (
            f"\n\nPrevious curation: {len(prev_inc)} included albums. "
            "Build on these decisions, add any new providers."
        )

    return await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(agent, prompt, deps), timeout=timeout,
        ),
        phase="curation",
    )


# ── Large discography flow (batched) ───────────────────────────────────────

async def _run_large(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str,
    api_key: str,
    timeout: int,
    existing_curation: dict | None = None,
    is_music: bool = False,
) -> CuratedSeries:
    ai_provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=ai_provider)

    # ── Step 1: Discovery — find artists + fetch discographies ─────────
    console.print("\n[bold cyan]Discovery[/]\n")

    all_albums: list[dict] = []
    artist_ids: dict[str, list[str]] = {}

    for p in providers:
        artists = p.search_artists(query)
        if not artists:
            console.print(f"  [{p.name}] No artist found")
            continue

        artist = artists[0]
        artist_ids.setdefault(p.name, []).append(artist.id)
        console.print(
            f"  [{p.name}] Artist: [bold]{artist.name}[/] [{artist.id}]",
        )

        albums = p.artist_albums(artist.id)
        for a in albums:
            all_albums.append({
                "provider": p.name, "id": a.id, "name": a.name,
                "release_date": a.release_date, "total_tracks": a.total_tracks,
            })
        console.print(f"  [{p.name}] {len(albums)} albums")

    console.print(f"\n  Total: {len(all_albums)} albums across {len(providers)} providers\n")

    # ── Step 2: Metadata extraction (tiny call, no tools) ──────────────
    console.print("[bold cyan]Metadata[/]\n")

    sample_titles = [a["name"] for a in all_albums[:40]]
    provider_list = ", ".join(f"{k}: {v}" for k, v in artist_ids.items())

    metadata_agent: Agent[None, SeriesMetadata] = Agent(
        model, output_type=SeriesMetadata,
        system_prompt=_METADATA_SYSTEM_PROMPT, retries=2,
    )
    meta: SeriesMetadata = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(
                metadata_agent,
                f"Series: {query!r}\nProviders: {provider_list}\n"
                f"Sample titles:\n" + "\n".join(f"  - {t}" for t in sample_titles),
                deps=None,
            ),
            timeout=120,
        ),
        phase="metadata",
    )
    # Ensure artist IDs are in metadata
    if not meta.provider_artist_ids:
        meta.provider_artist_ids = artist_ids

    console.print(
        f"  id={meta.id}  title={meta.title!r}  "
        f"pattern={meta.episode_pattern}  age={meta.age_note}\n",
    )

    # ── Step 3: Batched curation ───────────────────────────────────────
    batches = [
        all_albums[i : i + _BATCH_SIZE]
        for i in range(0, len(all_albums), _BATCH_SIZE)
    ]

    console.print(
        f"[bold cyan]Curation[/] — {len(all_albums)} albums in "
        f"{len(batches)} batches of ≤{_BATCH_SIZE}\n",
    )

    batch_agent = _build_batch_agent(model, is_music=is_music)
    all_decisions: list[AlbumDecision] = []
    total_inc = 0
    total_exc = 0
    episode_nums: list[int] = []

    for batch_num, batch in enumerate(batches, 1):
        # Progress context for the AI
        if episode_nums:
            progress = (
                f"Progress: {total_inc} included (episodes "
                f"{min(episode_nums)}–{max(episode_nums)}), "
                f"{total_exc} excluded."
            )
        else:
            progress = f"Progress: {total_inc} included, {total_exc} excluded."

        album_lines = "\n".join(
            f"  {a['provider']}:{a['id']} | {a['name']} | "
            f"{a['total_tracks']} tracks | {a['release_date']}"
            for a in batch
        )
        prompt = (
            f"Series: {meta.title!r}\n"
            f"Episode pattern: {meta.episode_pattern}\n"
            f"{progress}\n\n"
            f"Batch {batch_num}/{len(batches)} ({len(batch)} albums):\n\n"
            f"{album_lines}"
        )

        batch_deps = BatchDeps(providers=providers)
        result: BatchResult = await _run_with_retry(
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

        console.print(
            f"  Batch {batch_num}/{len(batches)}: "
            f"[green]+{n_inc}[/] [red]-{n_exc}[/]  "
            f"(total: {total_inc} included, {total_exc} excluded)",
        )

        all_decisions.extend(result.albums)

    console.print(
        f"\n  [bold]Total: [green]{total_inc} included[/]  "
        f"[red]{total_exc} excluded[/][/]\n",
    )

    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        keywords=meta.keywords,
        episode_pattern=meta.episode_pattern,
        albums=all_decisions,
        provider_artist_ids=meta.provider_artist_ids,
        age_note=meta.age_note,
        curator_notes=meta.curator_notes,
    )


# ── Dispatcher ─────────────────────────────────────────────────────────────

async def run_curation(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 1800,
    existing_curation: dict | None = None,
    is_music: bool = False,
) -> CuratedSeries:
    """Pick single-agent or batched flow based on discography size."""
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/red]")
        raise SystemExit(1)

    # Probe total album count across providers (results are cached by the
    # provider's diskcache, so _run_large won't re-fetch).
    total_albums = 0
    for p in providers:
        artists = p.search_artists(query)
        if artists:
            albums = p.artist_albums(artists[0].id)
            total_albums += len(albums)

    if total_albums <= _LARGE_THRESHOLD:
        console.print(f"  {total_albums} albums — using [bold]single-agent[/] flow\n")
        result = await _run_small(
            query, providers,
            model_name=model_name, api_key=api_key,
            timeout=timeout, existing_curation=existing_curation,
            is_music=is_music,
        )
    else:
        console.print(f"  {total_albums} albums — using [bold]batched[/] flow\n")
        result = await _run_large(
            query, providers,
            model_name=model_name, api_key=api_key,
            timeout=timeout, existing_curation=existing_curation,
            is_music=is_music,
        )

    # Persist content type so re-curation uses the right prompt.
    if is_music:
        result.content_type = "music"

    return result


# ── Save / display ────────────────────────────────────────────────────────

def save_curation(series: CuratedSeries) -> Path:
    path = CURATION_DIR / f"{series.id}.json"
    data = {
        "id": series.id,
        "title": series.title,
        "content_type": series.content_type,
        "aliases": series.aliases,
        "keywords": series.keywords,
        "episode_pattern": series.episode_pattern,
        "provider_artist_ids": series.provider_artist_ids,
        "age_note": series.age_note,
        "curator_notes": series.curator_notes,
        "curated_at": datetime.now(UTC).isoformat(),
        "albums": [a.model_dump() for a in series.albums],
    }
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


def print_summary(series: CuratedSeries):
    from rich.markup import escape

    included = series.included()
    excluded = [a for a in series.albums if not a.include]
    eps = [a.episode_num for a in included if a.episode_num is not None]
    providers_used = sorted(set(a.provider for a in included))

    ep_pat = series.episode_pattern or "(none)"
    pattern = escape(str(ep_pat))

    console.print(Panel(
        f"[bold]{escape(series.title)}[/]  [dim]{series.id}[/]\n"
        f"Providers: {', '.join(f'{k}: {v}' for k, v in series.provider_artist_ids.items())}\n"
        f"Episodes: {len(included)} included · {len(excluded)} excluded\n"
        f"Range: {min(eps) if eps else '—'}–{max(eps) if eps else '—'}\n"
        f"Pattern: {pattern}",
        title="✅ Curated",
        border_style="green",
    ))

    # Gap detection
    if eps:
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        if gaps:
            console.print(
                f"[yellow]⚠ Gaps: {gaps[:20]}"
                f"{'…' if len(gaps) > 20 else ''}[/]",
            )

    # Episode table
    table = Table(box=box.SIMPLE, title=f"Included (first 10 of {len(included)})")
    table.add_column("Ep", width=5, justify="right")
    table.add_column("Provider", width=12)
    table.add_column("Title", min_width=40)
    table.add_column("ID", width=14, style="dim")
    for a in included[:10]:
        table.add_row(
            str(a.episode_num) if a.episode_num else "—",
            a.provider, a.title[:50], a.album_id[:14],
        )
    if len(included) > 10:
        table.add_row("…", "", f"({len(included) - 10} more)", "")
    console.print(table)

    if series.age_note:
        console.print(f"\n👶 Age: {series.age_note}")

    if series.curator_notes:
        console.print(f"\n[dim]Notes: {escape(series.curator_notes[:200])}[/]")

    if excluded:
        console.print(f"\n[dim]Excluded ({len(excluded)}):[/dim]")
        for a in excluded[:5]:
            console.print(f"  [dim]{a.provider}: {a.title} — {a.exclude_reason}[/dim]")

    console.print(f"\n[dim]Review with: mise run catalog-review-ai -- {series.id}[/]")


# ── CLI ────────────────────────────────────────────────────────────────────

def _init_providers(provider: str, *, no_cache: bool = False) -> list[CatalogProvider]:
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider(use_cache=not no_cache))
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider(use_cache=not no_cache))
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)
    return providers


def _curate_one(
    query: str,
    providers: list[CatalogProvider],
    *,
    model: str,
    timeout: int,
    existing_curation: dict | None = None,
    is_music: bool = False,
) -> Path | None:
    try:
        if is_music:
            console.print(f"  [cyan]Mode: music artist (not Hörspiel)[/]")
        series = asyncio.run(
            run_curation(
                query, providers,
                model_name=model, timeout=timeout,
                existing_curation=existing_curation,
                is_music=is_music,
            ),
        )
        path = save_curation(series)
        print_summary(series)
        console.print(f"[green]Saved to {path}[/green]")
        return path
    except Exception as e:
        console.print(f"[red]Failed to curate {query}: {e}[/red]")
        return None


@click.command()
@click.argument("query", required=False)
@click.option("--all", "run_all", is_flag=True, help="Curate all series in the catalog")
@click.option("--force", is_flag=True, help="Re-curate even if curation JSON exists")
@click.option("--model", default=_DEFAULT_MODEL, help="AI model to use")
@click.option("--timeout", default=1800, help="Timeout per series in seconds (default 30 min)")
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--no-cache", is_flag=True, help="Bypass provider API cache")
@click.option("--music", is_flag=True, help="Curate as music artist (not Hörspiel series)")
def curate(
    query: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
    no_cache: bool,
    music: bool,
):
    """AI-curate a Hörspiel series or music artist across providers.

    Pass a series name to curate one, or --all to curate the entire catalog.
    Existing curations are skipped unless --force is given.
    Use --music for children's music artists (includes albums, not episodes).
    """
    if not query and not run_all:
        console.print("[red]Provide a series name or use --all[/red]")
        raise SystemExit(1)

    providers = _init_providers(provider, no_cache=no_cache)
    provider_names = ", ".join(p.name for p in providers)

    if query and not run_all:
        console.print(
            Panel(
                f"Curating [bold]{query}[/bold] with {model}\n"
                f"Providers: {provider_names}",
                title="lauschi-catalog curate",
            ),
        )
        _curate_one(query, providers, model=model, timeout=timeout, is_music=music)
        return

    # --all mode
    from lauschi_catalog.catalog.loader import load_catalog

    entries = load_catalog()
    total = len(entries)
    skipped = 0
    succeeded = 0
    failed = 0
    failed_ids: list[str] = []

    console.print(
        Panel(
            f"Curating [bold]{total} series[/bold] with {model}\n"
            f"Providers: {provider_names}\n"
            f"Force: {force}",
            title="lauschi-catalog curate --all",
        ),
    )

    for i, entry in enumerate(entries):
        curation_path = CURATION_DIR / f"{entry.id}.json"
        existing = None
        if curation_path.exists():
            if not force:
                skipped += 1
                continue
            existing = json.loads(curation_path.read_text())

        console.print(
            f"\n[bold]({i + 1}/{total})[/bold] {entry.title} "
            f"[dim]({succeeded} done, {failed} failed, {skipped} skipped)[/dim]",
        )

        # Detect music artists: check existing curation JSON first (persisted
        # content_type), then fall back to no episode_pattern in catalog entry.
        entry_is_music = False
        if existing and existing.get("content_type") == "music":
            entry_is_music = True
        elif not entry.episode_pattern:
            entry_is_music = True
        path = _curate_one(
            entry.title, providers,
            model=model, timeout=timeout,
            existing_curation=existing,
            is_music=entry_is_music,
        )
        if path:
            succeeded += 1
        else:
            failed += 1
            failed_ids.append(entry.id)

    console.print(
        f"\n[bold]Results:[/bold] {succeeded} curated, "
        f"{skipped} skipped, {failed} failed",
    )
    if failed_ids:
        console.print(f"[red]Failed: {', '.join(failed_ids)}[/red]")
