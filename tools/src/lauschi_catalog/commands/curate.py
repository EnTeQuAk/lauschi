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
from lauschi_catalog._opencode import build_opencode_model
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.providers import Album, CatalogProvider
from lauschi_catalog.providers._validate import explain_invalid, is_valid_id
from lauschi_catalog.retry import is_retryable

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
CURATION_DIR.mkdir(parents=True, exist_ok=True)

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
    episode_num: int | None = Field(description="Episode number extracted from the album title using the series episode_pattern regex")
    title: str
    exclude_reason: str | None = None
    # Populated after the agent returns, by joining (provider, album_id)
    # against the discovery-phase album list. Persisted in the curation
    # JSON so the review and verify phases can render release_date in
    # their prompts without re-fetching from the provider, and so the
    # release-order strategy (when enabled) has the data it needs.
    release_date: str | None = None


_EPISODE_PATTERN_DESCRIPTION = (
    "Regex(es) with one capture group that yields an integer episode "
    "number (`int(group)` MUST succeed). Use None when titles carry "
    "no digit-string episode markers — e.g. named episodes (fairy "
    "tales, themed releases), sequel markers like 'Inside Out 2', or "
    "story-based titles. When None, albums display sorted by "
    "release_date in the UI; there is NO penalty for None and no "
    "benefit to inventing a catch-all. Do NOT emit '(\\\\d+)' just "
    "to populate this field: that captures any digit anywhere in a "
    "title and silently breaks when the catalog grows to include "
    "albums with years, volume counts, or anniversary numbers."
)

_EPISODE_PATTERN_EXAMPLES = [
    None,
    r"^Folge (\d+):",
    [r"^(\d{3})/", r"^Folge (\d+):"],
]


class CuratedSeries(BaseModel):
    """Complete curation result for a series or music artist."""

    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = Field(
        default=None,
        description=_EPISODE_PATTERN_DESCRIPTION,
        examples=_EPISODE_PATTERN_EXAMPLES,
    )
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
            # Numbered episodes sort by number. Unnumbered (named
            # episodes, fairy tales, etc.) fall back to release_date
            # so users see them in chronological order rather than
            # alphabetical. The `is None` first element keeps the
            # numbered bucket ahead of the unnumbered without
            # inventing a magic-int sentinel; tuple compares stop
            # at the bool when buckets differ, so None never has
            # to compare against int.
            key=lambda a: (
                a.episode_num is None, a.episode_num,
                a.release_date or "",
                a.title,
            ),
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
    episode_pattern: str | list[str] | None = Field(
        default=None,
        description=_EPISODE_PATTERN_DESCRIPTION,
        examples=_EPISODE_PATTERN_EXAMPLES,
    )
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
    # Pattern starts at whatever the metadata phase decided. The batch
    # agent can revise it via propose_pattern_update when it observes
    # titles the current pattern misses. Subsequent batches see the
    # revised value in their prompts; after all batches we re-extract
    # episode_num across every decision using the final pattern.
    pattern: str | list[str] | None = None
    pattern_revisions: list[str | list[str]] = field(default_factory=list)
    # All discovery-phase titles, carried so propose_pattern_update can
    # verify that a proposed regex actually captures digits before
    # accepting it. Without this, a batch agent that proposed
    # `^(.+?) \(...\)$` (capturing story names, not numbers) silently
    # installed a dead pattern in the SimsalaGrimm run.
    titles: list[str] = field(default_factory=list)


@dataclass
class MetadataDeps:
    """Deps for the metadata-extraction agent.

    Carries the full discography titles so the agent's
    check_pattern_coverage tool can score a proposed episode_pattern
    against every album, not just the sample in the prompt.
    """
    titles: list[str]


def _stratified_sample(items: list, n: int) -> list:
    """Pick ``n`` items spread evenly across ``items`` rather than
    taking the head.

    Provider APIs return albums in some order (Spotify: roughly
    newest-first). Taking the first N can blind the metadata agent
    to era-specific naming conventions — e.g., ddF episodes 1-170
    use ``NNN/Title`` format and 175+ use ``Folge XXX:``. If the
    head-40 sample only contains the modern format, the agent emits
    a single-pattern regex and the older format silently loses its
    episode numbers across the entire run.
    """
    if len(items) <= n:
        return list(items)
    step = len(items) / n
    return [items[int(i * step)] for i in range(n)]


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
Individual episodes: 20-60 min runtime. Track count varies by provider
(1-5 on Apple Music, 20-40 on Spotify where chapters are individual tracks).

## Exclude (with exclude_reason)
- Box sets / compilations ("Folge 1-10", "Jubiläumsbox", "Best of")
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

If titles carry no episode number, leave episode_num=None for those
albums. They'll display sorted by release_date downstream — don't
invent numbers.

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

Given a series name and a sample of albums from its discography across
multiple providers — title, total_tracks, release_date — provide:
- id: lowercase snake_case identifier (e.g., "paw_patrol", "die_drei_fragezeichen")
- title: display name (e.g., "PAW Patrol", "Die drei ???")
- aliases: alternate names the series goes by (different languages, abbreviations)
- episode_pattern: regex (or list of regexes) with exactly 1 capture group each
  for the episode number. The captured group MUST be a digit string —
  `int(group)` has to succeed. Use a list when a series changed naming
  conventions, e.g. ["^(\\d{3})/", "^Folge (\\d+):"] — tried in order, first
  match wins. If the discography uses NAMED episodes (e.g. fairy tale titles,
  themed releases) without any numbering, set this to None and skip the
  coverage check below. Albums without an episode number sort by
  release_date downstream — no fake numbers are invented.
- age_note: "Suitable from 3+", "Suitable from 5+", or "Recommended 8+"
- curator_notes: anything noteworthy (spinoffs, format changes, etc.)
- provider_artist_ids: {provider: [artist_ids]} for each provider found

Do NOT classify individual albums. Just set up the metadata.

The sample lines carry "title | total_tracks | release_date". Title is
the primary signal for episode_pattern, but track count helps spot
compilations (huge counts) vs episodes (1-50ish), and release_date
order can hint at episode order when titles lack numbers.

## episode_pattern verification (REQUIRED if pattern is not None)

If the series uses numbered episodes, you MUST call the
check_pattern_coverage tool after deciding on a pattern. The sample
titles in this prompt are a stratified slice of the discography,
but the tool runs against EVERY title. Long-running series often
have multiple naming conventions for different eras (e.g.,
"001/Title" for episodes 1-170 plus "Folge 171: Title" for newer
releases) — the sample may not show both.

The tool returns two failure buckets:
  - unmatched_regex_samples: titles where the regex didn't match.
    Fix by adding alternative regex(es) to cover other eras.
  - non_numeric_capture_samples: titles where the regex matched
    but capture group 1 was non-numeric (e.g. you used `(.+)` and
    captured the whole title). Fix by tightening group 1 to `(\\d+)`.

If coverage < 80% AND most failures are unmatched_regex_samples,
add alternation. If most are non_numeric_capture_samples, your
group is wrong. Re-test until coverage > 90% or remaining
unmatched are legitimate non-episodes (specials, compilations).

If the series uses NAMED episodes without numbering (fairy tales,
themes, etc.), set episode_pattern=None and DO NOT call the tool
— no pattern can succeed, repeated tries waste your timeout
budget.
"""


_METADATA_MUSIC_SYSTEM_PROMPT = """\
You are setting up metadata for a DACH children's MUSIC artist
catalog entry — NOT a Hörspiel series. Albums here are standalone
music releases, not numbered episodes.

Given an artist name and a sample of album titles from their
discography across multiple providers, provide:
- id: lowercase snake_case identifier (e.g., "detlev_joecker")
- title: display name
- aliases: alternate names the artist goes by
- episode_pattern: leave as None. Music albums don't have episode
  numbers and the catalog UI doesn't show "Folge N" for music.
- age_note: "Suitable from 2+", "Suitable from 3+", "Suitable from
  5+", or "Suitable from 6+" depending on the music's energy and
  themes
- curator_notes: anything noteworthy (genre, style, collaborations)
- provider_artist_ids: {provider: [artist_ids]} for each provider found

Do NOT classify individual albums. Just set up the metadata.
Do NOT call any tools — there are none available for music metadata.
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
- Episode runtime 20-60 min. Track count varies by provider (1-5 on Apple Music,
  20-40 on Spotify where chapters are individual tracks).
- Albums from different providers for the same episode: include BOTH

## Episode numbers
The series context includes an episode_pattern (regex with 1 capture group).
Apply it to each album title to extract the episode number.
- Match: set episode_num to the captured integer
- No match: set episode_num to null (still include if it's a valid episode)
- Examples: "Folge 123: Title" → 123, "123/Title" → 123, "Teil 5" → 5

## Exclude (set exclude_reason)
- Compilations / box sets ("Folge 1-10", "Best of")
- Foreign language releases (Polish, Spanish, etc.)
- Single music tracks (1 track, not a Hörspiel)
- Multi-artist compilations ("Kinderparty Hits", "Nick Jr.'s …")
- Remixes, sped-up versions, sing-alongs, soundtracks
- Audiobooks ("ungekürzt") that are book readings, not radio dramas
- Duplicates of already-included episodes (same episode number, same provider)

## When unsure
Call get_album_details to see the track listing, that usually resolves it.
Only fetch details for albums where the title + track count is genuinely
ambiguous. Most episodes are obvious from the title alone.

## When the episode pattern doesn't match this batch

Only consider propose_pattern_update when titles in this batch
CONTAIN digit-string episode numbers that the current pattern
doesn't match. The captured group MUST yield an integer
(`int(group)` must succeed) — that's the hard contract enforced
by the tool, which will reject non-numeric captures.

Example of a legitimate update: pattern is `^Folge (\\d+):` but
this batch shows `001/Title`, `002/Title`, etc. The new form
also has digit captures, so call:
  propose_pattern_update(patterns=["^Folge (\\d+):", "^(\\d+)/"])

When NOT to propose:
- Titles are structured but have no episode number (e.g. fairy
  tale names with consistent suffix like `Aschenputtel (Das
  Original-Hörspiel zur TV Serie)`). Structure ≠ numbering. Leave
  episode_pattern as None — the framework sorts unnumbered
  episodes by release_date downstream.
- Only one or two outliers (specials, untitled releases). Pattern
  changes need a systematic mismatch.
- The captured group would be a string, not a digit. Patterns
  like `^(.+?) \\(Subtitle\\)$` capture story names and get
  rejected by the tool.

## Important
- Produce an AlbumDecision for EVERY album in this batch.
- album_id must EXACTLY match the IDs provided.
- provider must EXACTLY match the provider provided.
- Do NOT invent album IDs.
"""


def _dry_run_prompts(query: str, is_music: bool = False) -> None:
    """Print assembled prompts without calling the API."""
    single = _MUSIC_SYSTEM_PROMPT if is_music else _SYSTEM_PROMPT
    batch = _MUSIC_BATCH_SYSTEM_PROMPT if is_music else _BATCH_SYSTEM_PROMPT

    console.print(Panel("Single-agent system prompt", border_style="blue"))
    console.print(single)
    console.print()

    console.print(Panel("Batch-agent system prompt", border_style="blue"))
    console.print(batch)
    console.print()

    console.print(Panel("Metadata system prompt", border_style="blue"))
    console.print(_METADATA_SYSTEM_PROMPT)
    console.print()

    # Sample batch user prompt
    sample_batch = [
        {"provider": "spotify", "id": "abc123", "name": "Folge 1: Der Anfang", "total_tracks": 3, "release_date": "2020-01-15"},
        {"provider": "apple_music", "id": "def456", "name": "Folge 2: Die Reise", "total_tracks": 4, "release_date": "2020-03-20"},
    ]
    album_lines = "\n".join(
        f"  {a['provider']}:{a['id']} | {a['name']} | {a['total_tracks']} tracks | {a['release_date']}"
        for a in sample_batch
    )
    sample_user = (
        f"Series: {query!r}\n"
        f"Episode pattern: ^Folge (\\d+):\n"
        f"Progress: 0 included, 0 excluded.\n\n"
        f"Batch 1/1 (2 albums):\n\n{album_lines}"
    )
    console.print(Panel("Sample batch user prompt", border_style="blue"))
    console.print(sample_user)


# ── Agent builders ─────────────────────────────────────────────────────────

def _build_small_agent(
    model_name: str, api_key: str, *, is_music: bool = False,
) -> Agent[Deps, CuratedSeries]:
    model = build_opencode_model(model_name, api_key)
    prompt = _MUSIC_SYSTEM_PROMPT if is_music else _SYSTEM_PROMPT
    agent: Agent[Deps, CuratedSeries] = Agent(
        model,
        output_type=CuratedSeries,
        system_prompt=prompt,
        retries=2,
    )

    @agent.tool
    def search_artists(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search all providers for artists by name.

        WHEN TO USE:
        - First step of every curation: find the correct artist on each provider.
        - Artist search on a provider returns no results: try a variant
          (e.g. "Benjamin Blümchen" → "Benjamin Blümchen Europa").

        WHEN NOT TO USE:
        - Don't search for sub-series, spin-offs, or compilations — those are
          curated as separate series entries. Stick to the primary artist.

        Returns: list of {provider, id, name, genres}
        """
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
        """Fetch every album released by an artist on a specific provider.

        WHEN TO USE:
        - After search_artists identified the correct artist_id for a provider.
        - Results are cached per run — safe to call again if you need the list.

        WHEN NOT TO USE:
        - Don't call for every batch; call once per provider per artist and
          rely on the cached result.

        Returns: list of {provider, id, name, release_date, total_tracks}
        """
        if not is_valid_id(provider, artist_id):
            # Reject obvious provider/id mismatches (e.g., a Spotify-format
            # 22-char id passed with provider='apple_music') before the
            # call hits the API. Returning a descriptive error here lets
            # the agent self-correct instead of 4xx-ing.
            return [{"error": explain_invalid(provider, artist_id)}]

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
        """Fetch full album details (track listing, label, runtime) from a provider.

        WHEN TO USE:
        - Title + track count genuinely ambiguous (e.g. "Die schönsten Lieder"
          could be a music compilation or a Hörspiel with songs inside).
        - Episode number unclear from title alone (e.g. "Brainwash" needs
          track names to confirm it's episode 147).
        - Unusually high/low track count: 1 track = likely a single, not a
          Hörspiel; 120 tracks = possibly a Kopfhörer-Hörspiel or double episode.

        WHEN NOT TO USE:
        - Title clearly matches the episode pattern (e.g. "Folge 42: Der Geist")
          — the pattern already extracted the number, no details needed.
        - Obvious compilation from title alone ("Best of", "Jubiläumsbox",
          "Folge 1–10") — exclude immediately without burning a tool call.

        BATCHING: Pass up to 5 album IDs in one call. Batch IDs when multiple
        albums from the same provider are ambiguous.

        Returns: list of {provider, id, name, release_date, total_tracks,
        label, artists, tracks}. ``release_date`` is ISO format (YYYY-MM-DD
        or YYYY) — useful for spotting compilations (recent date, old
        content), original-vs-remaster decisions (older = original), and
        inferring chronological order when titles lack episode numbers.
        ``artists`` is the credited primary artist string — use to spot
        cross-artist compilations or wrong-artist matches.
        """
        results = []
        # Reject malformed ids per provider (Spotify 22-base62 vs
        # Apple Music all-digit). Invalid ids are reported in-line
        # so the agent sees which one failed without poisoning the
        # whole batch.
        invalid = [aid for aid in album_ids if not is_valid_id(provider, aid)]
        valid_ids = [aid for aid in album_ids if is_valid_id(provider, aid)]
        for bad in invalid:
            results.append({"id": bad, "error": explain_invalid(provider, bad)})

        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return results or []
        for aid in valid_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider, "id": album.id, "name": album.name,
                    "release_date": album.release_date,
                    "total_tracks": album.total_tracks,
                    "label": album.label,
                    "artists": album.artists,
                    "tracks": [{"name": t.name, "duration_ms": t.duration_ms}
                               for t in album.tracks],
                }
                ctx.deps.seen_details[key] = detail
                results.append(detail)
                console.print(f"  [dim]🔎 {provider}:{aid[:8]}… → {album.total_tracks} tracks[/]")
        return results

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search the web for series info. Max 2 searches per curation.

        WHEN TO USE:
        - Unclear whether the artist is a Hörspiel or Hörbuch/music series.
        - Need to verify episode count (e.g. "does this series really have 200 episodes?").
        - Confirm whether a specific album is a compilation vs. original release.

        WHEN NOT TO USE:
        - Well-known series with unambiguous metadata (TKKG, Die drei ???,
          Bibi Blocksberg) — don't waste searches on obvious cases.
        - Album titles already clearly indicate include/exclude.

        Good queries:
        - '"Series Name" Hörspiel Episodenliste'
        - 'site:hoerspiele.de "Series Name"'

        Returns: list of {title, url, snippet, age}
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


# Backwards-compat alias for tests and internal callers; the canonical
# home is matcher.py since both curate and review need it.
from lauschi_catalog.catalog.matcher import (
    compute_pattern_coverage as _compute_pattern_coverage,
)


def _build_metadata_agent(
    model, *, is_music: bool = False,
) -> Agent[MetadataDeps, SeriesMetadata]:
    """Metadata-extraction agent.

    For Hörspiel series, the agent must call check_pattern_coverage
    before finalizing — that's how it learns whether the pattern it
    inferred from the sample actually covers the full discography.

    For music artists, episode_pattern is meaningless (music albums
    aren't numbered), so the tool isn't registered and the prompt
    doesn't ask for verification. Without this split, a music
    metadata run obeys the "MUST call check_pattern_coverage"
    instruction with a None pattern, gets a tool error, and may
    invent a bogus pattern to satisfy the instruction.
    """
    system_prompt = (
        _METADATA_MUSIC_SYSTEM_PROMPT if is_music else _METADATA_SYSTEM_PROMPT
    )
    agent: Agent[MetadataDeps, SeriesMetadata] = Agent(
        model,
        output_type=SeriesMetadata,
        system_prompt=system_prompt,
        retries=2,
    )

    if is_music:
        return agent

    @agent.tool
    def check_pattern_coverage(
        ctx: RunContext[MetadataDeps],
        pattern: str | list[str],
    ) -> dict:
        """Test a proposed episode_pattern against ALL discovered titles.

        Returns coverage stats. The pattern's first capture group MUST
        capture a digit string (the episode number). A title can fail
        in two distinct ways:
          - regex_no_match: the regex didn't find a match at all
          - non_numeric_capture: regex matched but capture group 1
            wasn't an integer (e.g. you used `(.*)` and captured the
            whole title, or your group caught text instead of digits)

        If non_numeric_capture is high, the regex itself is fine but
        the capture group is wrong — narrow group 1 to `(\\d+)`.

        If the discography uses named/themed episodes (fairy tales,
        themes) instead of numbers, no pattern can succeed: return
        episode_pattern=None without calling this tool again.
        """
        result = _compute_pattern_coverage(ctx.deps.titles, pattern)
        if "error" not in result:
            console.print(
                f"  [dim]✅ check_pattern_coverage({pattern!r}) → "
                f"{result['matched']}/{result['total']} = "
                f"{result['coverage']:.0%}[/]",
            )
        return result

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

    if not is_music:
        @agent.tool
        def propose_pattern_update(
            ctx: RunContext[BatchDeps],
            patterns: list[str],
        ) -> str:
            """Replace the current episode_pattern with a new list.

            Use when the titles in your current batch are episode-numbered
            but the active pattern doesn't match them. Provide a list
            (typically the existing pattern(s) PLUS additional regex(es)
            for the new naming form). Each regex must compile, have
            ≥1 capture group, AND its first capture group must yield a
            digit string when matched against the discovery-phase titles
            — otherwise the pattern is dead weight (it would extract
            zero episode numbers downstream).

            The new pattern propagates to subsequent batches' prompts
            and is used to re-extract episode_num across every decision
            at the end of the run. Don't propose for sporadic outliers —
            only systematic mismatches.
            """
            if not patterns:
                return "patterns list cannot be empty"
            for p in patterns:
                try:
                    compiled = re.compile(p)
                except re.error as e:
                    return f"invalid regex {p!r}: {e}"
                if compiled.groups < 1:
                    return f"pattern {p!r}: needs ≥1 capture group"

            # Verify the proposed pattern actually extracts integer
            # episode numbers from at least one title. A non-numeric
            # capture (e.g. `^(.+?) \(Subtitle\)$` capturing story
            # names) passes the compile check but silently installs
            # a dead pattern — exactly the SimsalaGrimm regression
            # we're guarding against. Re-uses the same coverage logic
            # the metadata phase exposes to the metadata agent.
            if ctx.deps.titles:
                check = _compute_pattern_coverage(ctx.deps.titles, patterns)
                if "error" in check:
                    return check["error"]
                if check["matched"] == 0:
                    non_numeric = check.get("non_numeric_capture_samples") or []
                    if non_numeric:
                        sample = non_numeric[0]
                        return (
                            f"pattern {patterns!r}: matches titles but "
                            f"capture group 1 isn't numeric — captured "
                            f"{sample['captured']!r} from "
                            f"{sample['title']!r}. Episode numbers must "
                            f"be int-parseable. Tighten group 1 to "
                            f"(\\d+) or similar. If the series has no "
                            f"episode numbers, don't propose a pattern "
                            f"— leave it as None and the framework "
                            f"sorts by release_date."
                        )
                    return (
                        f"pattern {patterns!r}: didn't match any of "
                        f"{len(ctx.deps.titles)} discovery titles. "
                        f"Check the regex against the sample titles "
                        f"in your prompt before re-trying."
                    )

            new_pattern: str | list[str] = (
                patterns[0] if len(patterns) == 1 else list(patterns)
            )
            ctx.deps.pattern = new_pattern
            ctx.deps.pattern_revisions.append(new_pattern)
            console.print(
                f"  [cyan]🔄 propose_pattern_update → {new_pattern}[/]",
            )
            return (
                f"Pattern updated to {new_pattern}. Subsequent batches "
                f"see this pattern; episode_num is re-extracted across "
                f"all decisions at the end of the run."
            )

    @agent.tool
    def get_album_details(
        ctx: RunContext[BatchDeps], provider: str, album_ids: list[str],
    ) -> list[dict]:
        """Fetch full album details (track listing, label, runtime) from a provider.

        WHEN TO USE:
        - Title + track count genuinely ambiguous (e.g. "Die schönsten Lieder"
          could be a music compilation or a Hörspiel with songs inside).
        - Episode number unclear from title alone.
        - Unusually high/low track count: 1 track = likely a single; 120+ tracks
          = possibly a Kopfhörer-Hörspiel or double episode.

        WHEN NOT TO USE:
        - Title clearly matches the episode pattern — the pattern already
          extracted the number, no details needed.
        - Obvious compilation from title alone ("Best of", "Jubiläumsbox",
          "Folge 1–10") — exclude immediately without burning a tool call.

        BATCHING: Pass up to 5 album IDs in one call. Batch IDs when multiple
        albums from the same provider are ambiguous.

        Returns: list of {provider, id, name, release_date, total_tracks,
        label, artists, tracks (first 10)}. ``release_date`` and
        ``artists`` are populated from the same provider response that
        gives you the track listing — they're free, no extra fetch.
        Use ``release_date`` for original-vs-remaster and dedup
        decisions; ``artists`` to catch cross-artist compilations.
        """
        results = []
        # Same provider/id format guard as the small-flow agent — see
        # providers/_validate.py for the rationale.
        invalid = [aid for aid in album_ids if not is_valid_id(provider, aid)]
        valid_ids = [aid for aid in album_ids if is_valid_id(provider, aid)]
        for bad in invalid:
            results.append({"id": bad, "error": explain_invalid(provider, bad)})

        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return results or []
        for aid in valid_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                console.print(f"  [dim]🔎 {provider}:{aid[:8]}… → (cached)[/]")
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider, "id": album.id, "name": album.name,
                    "release_date": album.release_date,
                    "total_tracks": album.total_tracks,
                    "label": album.label,
                    "artists": album.artists,
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


# Re-export so existing tests/imports of curate._is_retryable keep
# working. New code should import is_retryable from
# lauschi_catalog.retry directly.
_is_retryable = is_retryable


async def _run_with_retry(coro_factory, *, phase: str = ""):
    last_err: Exception | None = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            return await coro_factory()
        except asyncio.TimeoutError:
            raise
        except Exception as e:
            last_err = e
            err_str = str(e)
            # Don't dump the full traceback: the SDK formats raw response
            # bodies into exception messages and a 1000-char slice can
            # carry request headers (incl. Authorization) into the log.
            # The exception type + message is enough to diagnose, and a
            # user can re-run with PYTHONFAULTHANDLER=1 if they want more.
            if is_retryable(e) and attempt < _MAX_RETRIES:
                console.print(
                    f"[yellow]{phase} attempt {attempt}/{_MAX_RETRIES} "
                    f"failed ({type(e).__name__}), retrying in "
                    f"{_RETRY_DELAY}s…[/]",
                )
                await asyncio.sleep(_RETRY_DELAY)
                continue
            console.print(
                f"[red]{phase} failed: {type(e).__name__}: "
                f"{escape(err_str[:300])}[/]",
            )
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

    series = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(agent, prompt, deps), timeout=timeout,
        ),
        phase="curation",
    )

    # Hydrate release_date on every decision from the discovery cache
    # the agent populated via get_artist_albums. The agent's schema
    # doesn't ask for release_date so it never echoes it; we want the
    # field on disk for review/verify and the release-order strategy.
    album_index: dict[tuple[str, str], dict] = {}
    for entries in deps.seen_albums.values():
        for src in entries:
            album_index[(src["provider"], src["id"])] = src
    for d in series.albums:
        if d.release_date:
            continue
        src = album_index.get((d.provider, d.album_id))
        if src:
            d.release_date = src.get("release_date") or None

    return series


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
    known_artist_ids: dict[str, list[str]] | None = None,
) -> CuratedSeries:
    model = build_opencode_model(model_name, api_key)

    # ── Step 1: Discovery — find artists + fetch discographies ─────────
    console.print("\n[bold cyan]Discovery[/]\n")

    all_albums: list[dict] = []
    artist_ids: dict[str, list[str]] = {}
    known_artist_ids = known_artist_ids or {}

    for p in providers:
        known = known_artist_ids.get(p.name) or []
        if known:
            # Canonical IDs from series.yaml. Skip search entirely; using
            # search_artists for known series risks picking the wrong
            # artist when there's a same-named band. This is the same
            # principle as _lock_series_id — series.yaml is authoritative
            # for identity.
            for aid in known:
                artist_ids.setdefault(p.name, []).append(aid)
                albums = p.artist_albums(aid)
                console.print(
                    f"  [{p.name}] canonical artist: [{aid}] → {len(albums)} albums",
                )
                for a in albums:
                    all_albums.append({
                        "provider": p.name, "id": a.id, "name": a.name,
                        "release_date": a.release_date,
                        "total_tracks": a.total_tracks,
                    })
            continue

        artists = p.search_artists(query)
        if not artists:
            console.print(f"  [{p.name}] No artist found")
            continue

        # No canonical id → fall back to search. Log the chosen artist's
        # name (not just the id) so the user can spot wrong-disambiguation
        # at glance, and flag if the search returned multiple plausible
        # candidates so they know it's a guess.
        artist = artists[0]
        artist_ids.setdefault(p.name, []).append(artist.id)
        if len(artists) > 1:
            others = ", ".join(a.name for a in artists[1:4])
            console.print(
                f"  [{p.name}] [yellow]chose[/] [bold]{artist.name}[/] "
                f"[{artist.id}] (also matched: {others})",
            )
        else:
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

    all_titles = [a["name"] for a in all_albums]
    # Stratified sample so era-mixed series (older NNN/ titles + newer
    # Folge XXX: titles) hand the metadata agent evidence of both
    # naming conventions.
    sample_albums = _stratified_sample(all_albums, 40)
    provider_list = ", ".join(f"{k}: {v}" for k, v in artist_ids.items())

    metadata_agent = _build_metadata_agent(model, is_music=is_music)
    meta_deps = MetadataDeps(titles=all_titles)
    # Sample lines carry release_date and total_tracks alongside the
    # title. Title alone tells half the story for series where streaming
    # stripped the "Folge N:" prefix — release_date order can hint at
    # episode order, total_tracks separates singles from full Hörspiele.
    sample_lines = "\n".join(
        f"  - {a['name']} | {a['total_tracks']} tracks"
        f" | {a.get('release_date') or '?'}"
        for a in sample_albums
    )
    meta: SeriesMetadata = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(
                metadata_agent,
                f"Series: {query!r}\nProviders: {provider_list}\n"
                f"Sample albums (title | tracks | release_date):\n"
                f"{sample_lines}",
                deps=meta_deps,
            ),
            timeout=120,
        ),
        phase="metadata",
    )
    # Ensure artist IDs are in metadata
    if not meta.provider_artist_ids:
        meta.provider_artist_ids = artist_ids

    # Orchestrator-side safety net: if the agent skipped or fumbled the
    # check_pattern_coverage tool, surface low coverage loudly. The
    # batch agent's propose_pattern_update tool is the recovery path,
    # but a heads-up here lets a human spot the issue early.
    if meta.episode_pattern and not is_music:
        from lauschi_catalog.catalog.matcher import extract_episode

        matched = sum(
            1 for t in all_titles if extract_episode(meta.episode_pattern, t) is not None
        )
        coverage = matched / len(all_titles) if all_titles else 0
        if coverage < 0.5:
            unmatched = [
                t for t in all_titles if extract_episode(meta.episode_pattern, t) is None
            ][:5]
            console.print(
                f"  [yellow]⚠ Low metadata-phase pattern coverage: "
                f"{matched}/{len(all_titles)} = {coverage:.0%}. "
                f"Batch agent may revise via propose_pattern_update.[/]",
            )
            for t in unmatched:
                console.print(f"  [dim]unmatched: {t[:80]}[/]")

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
    # Shared deps across all batches: pattern revisions made by the
    # batch agent in batch N propagate to batch N+1's prompt, and at
    # the end we re-extract episode_num for every decision using the
    # final pattern. Without sharing, each batch starts fresh and the
    # signal is thrown away (the whole reason the previous run
    # silently dropped 250+ ddF episode numbers).
    shared_deps = BatchDeps(
        providers=providers,
        pattern=meta.episode_pattern,
        titles=all_titles,
    )

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
        # Use shared_deps.pattern (not meta.episode_pattern) so any
        # revision made in an earlier batch is visible here.
        prompt = (
            f"Series: {meta.title!r}\n"
            f"Episode pattern: {shared_deps.pattern}\n"
            f"{progress}\n\n"
            f"Batch {batch_num}/{len(batches)} ({len(batch)} albums):\n\n"
            f"{album_lines}"
        )

        result: BatchResult = await _run_with_retry(
            lambda p=prompt: asyncio.wait_for(
                _run_agent(batch_agent, p, shared_deps), timeout=300,
            ),
            phase=f"batch {batch_num}/{len(batches)}",
        )

        # Hydrate release_date from the discovery dict — the agent
        # doesn't (and shouldn't) echo this field, but we want it on
        # every decision so review/verify renders dates in their
        # prompts without re-fetching.
        batch_index = {(a["provider"], a["id"]): a for a in batch}
        for a in result.albums:
            src = batch_index.get((a.provider, a.album_id))
            if src and not a.release_date:
                a.release_date = src.get("release_date") or None

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

    # If any batch revised the pattern, re-extract episode_num across
    # every decision so earlier batches benefit from the correction.
    # The agent's include/exclude decisions remain valid (they're
    # based on content, not the regex), only the extracted number
    # field is updated.
    final_pattern = shared_deps.pattern
    if shared_deps.pattern_revisions and final_pattern is not None:
        from lauschi_catalog.catalog.matcher import extract_episode

        re_extracted = 0
        for d in all_decisions:
            new_ep = extract_episode(final_pattern, d.title)
            if new_ep is not None and new_ep != d.episode_num:
                d.episode_num = new_ep
                re_extracted += 1
        console.print(
            f"  [cyan]Pattern revised mid-run: {meta.episode_pattern!r} "
            f"→ {final_pattern!r}. Re-extracted {re_extracted} episode "
            f"numbers across all batches.[/]\n",
        )

    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        episode_pattern=final_pattern,
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
    known_artist_ids: dict[str, list[str]] | None = None,
) -> CuratedSeries:
    """Pick single-agent or batched flow based on discography size."""
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/red]")
        raise SystemExit(1)

    # Probe total album count across providers (results are cached by the
    # provider's diskcache, so _run_large won't re-fetch). Use canonical
    # artist IDs when available so the probe doesn't take its own
    # disambiguation guess different from _run_large's.
    total_albums = 0
    known = known_artist_ids or {}
    for p in providers:
        ids = known.get(p.name) or []
        if not ids:
            artists = p.search_artists(query)
            if artists:
                ids = [artists[0].id]
        for aid in ids:
            albums = p.artist_albums(aid)
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
            known_artist_ids=known_artist_ids,
        )

    # Persist content type so re-curation uses the right prompt.
    if is_music:
        result.content_type = "music"

    return result


# ── Save / display ────────────────────────────────────────────────────────

def save_curation(series: CuratedSeries) -> Path:
    """Persist curate's findings into the curation JSON.

    The JSON file is canonical state shared across pipeline steps —
    curate, review, verify each own specific subkeys. This function
    reads the existing file (if any) and overwrites only the
    curate-owned fields (id, title, episode_pattern, albums, etc.).
    Anything we don't touch — review block, future fields owned by
    other pipeline steps — is naturally preserved. Same pattern
    save_review uses on its side.
    """
    path = CURATION_DIR / f"{series.id}.json"

    data: dict = {}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            # Don't silently overwrite an existing-but-unparseable file.
            # The risk: if the JSON had an approved review block (human
            # curation work) and got partially corrupted, restarting
            # from data={} would discard that work on the next save.
            # Surface loudly and abort; the user can inspect, repair,
            # or move the file aside before re-running.
            console.print(
                f"[red]Refusing to overwrite unreadable curation file[/red]\n"
                f"  Path: {path}\n"
                f"  Error: {type(exc).__name__}: {exc}\n"
                f"  This file may contain approved review state. "
                f"Inspect it before re-curating; rename/remove the file "
                f"if you intend to start fresh.",
            )
            raise SystemExit(1)

    data.update({
        "id": series.id,
        "title": series.title,
        "content_type": series.content_type,
        "aliases": series.aliases,
        "episode_pattern": series.episode_pattern,
        "provider_artist_ids": series.provider_artist_ids,
        "age_note": series.age_note,
        "curator_notes": series.curator_notes,
        "curated_at": datetime.now(UTC).isoformat(),
        "albums": [a.model_dump() for a in series.albums],
    })

    canonicalize(data)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


def print_summary(series: CuratedSeries):
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


def _lookup_catalog_entry(query: str):
    """Resolve ``query`` to a CatalogEntry when it matches a known series.

    ``query`` may be the user-typed ID (``detlev_joecker``) or the
    proper title (``Detlev Jöcker``). Returns the entry on first
    match or None when the query doesn't correspond to anything in
    series.yaml — that's a brand-new series the agent will discover
    and the caller falls back to the no-yaml path.

    Centralized so both the single-series CLI and any future caller
    (e.g. a re-curate-by-id tool) share one resolution rule.
    """
    from lauschi_catalog.catalog.loader import load_catalog

    try:
        entries = load_catalog()
    except Exception:
        return None
    # Exact id match wins over title (cheaper to type, no ambiguity).
    for entry in entries:
        if entry.id == query:
            return entry
    for entry in entries:
        if entry.title == query:
            return entry
    return None


def _resolve_is_music(
    entry_content_type: str | None,
    entry_has_pattern: bool,
    existing_content_type: str | None,
) -> bool:
    """Decide whether a series should be curated as music or Hörspiel.

    series.yaml is canonical: an explicit content_type there wins over
    everything else. This prevents the failure mode where a one-time
    misclassification in the curation file compounds across every
    --force re-curate. Resolution order:

    1. Explicit ``content_type`` on the catalog entry → that value.
    2. ``episode_pattern`` on the entry → Hörspiel (patterns are only
       meaningful for episode-numbered content).
    3. Existing curation file's ``content_type`` → legacy escape hatch
       for entries not yet migrated to series.yaml's explicit form.
    4. Default → music (no signals point at Hörspiel).
    """
    if entry_content_type in ("hoerspiel", "music"):
        return entry_content_type == "music"
    if entry_has_pattern:
        return False
    if existing_content_type == "music":
        return True
    return True


def _lock_series_id(series: CuratedSeries, canonical_id: str | None) -> CuratedSeries:
    """Force ``series.id`` to the canonical value when one is known.

    The metadata agent occasionally invents an id that doesn't match
    the canonical entry in series.yaml. The trigger is series titles
    with characters that fail the ``^[a-z][a-z0-9_]*$`` pattern —
    notably umlauts. pydantic-ai retries on validation failure with
    the error fed back to the model, and the retry sometimes produces
    sloppy transliterations: ``benjamin_blümchen`` → ``benjamin_bluechen``
    (lost both the umlaut→ue mapping and a literal ``m``).

    The previous-run consequence: a typo'd JSON file orphaned next to
    the canonical one. ``series.yaml`` is the source of truth for the
    id, so we override here and tell the user it happened.
    """
    if canonical_id and series.id != canonical_id:
        console.print(
            f"  [yellow]Locked id to canonical: {series.id!r} → "
            f"{canonical_id!r} (model output overridden by series.yaml)[/]",
        )
        series.id = canonical_id
    return series


def _curate_one(
    query: str,
    providers: list[CatalogProvider],
    *,
    model: str,
    timeout: int,
    series_id: str | None = None,
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_curation: dict | None = None,
    is_music: bool = False,
    dry_run: bool = False,
) -> Path | None:
    if dry_run:
        console.print(f"  [cyan]Mode: {'music artist' if is_music else 'Hörspiel'} (dry run)[/]")
        _dry_run_prompts(query, is_music=is_music)
        return None
    try:
        if is_music:
            console.print(f"  [cyan]Mode: music artist (not Hörspiel)[/]")
        series = asyncio.run(
            run_curation(
                query, providers,
                model_name=model, timeout=timeout,
                existing_curation=existing_curation,
                is_music=is_music,
                known_artist_ids=known_artist_ids,
            ),
        )
        _lock_series_id(series, series_id)
        path = save_curation(series)
        print_summary(series)
        console.print(f"[green]Saved to {path}[/green]")
        return path
    except Exception as e:
        # Some SDK exceptions have an empty str(e); fall back to the
        # type name so "Failed to curate Foo:" never appears blank.
        # escape() the message because pydantic-ai/regex error strings
        # can contain bracket-shaped fragments that Rich would parse
        # as markup and crash with MarkupError.
        msg = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
        console.print(f"[red]Failed to curate {query}: {escape(msg)}[/red]")
        return None


@click.command()
@click.argument("query", required=False)
@click.option("--all", "run_all", is_flag=True, help="Curate all series in the catalog")
@click.option("--force", is_flag=True, help="Re-curate even if curation JSON exists")
@click.option("--model", default=_DEFAULT_MODEL, help="AI model to use")
@click.option(
    "--timeout", default=3600,
    help="Timeout per series in seconds (default 60 min). Big series "
    "with many batches and tool calls genuinely take 30+ min; the old "
    "1800 default was timing out 14 series in the catalog.",
)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--no-cache", is_flag=True, help="Bypass provider API cache")
@click.option("--music", is_flag=True, help="Curate as music artist (not Hörspiel series)")
@click.option("--dry-run", is_flag=True, help="Print assembled prompts without calling the API")
def curate(
    query: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
    no_cache: bool,
    music: bool,
    dry_run: bool,
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
        # When the query matches a known catalog entry, use yaml as
        # canonical for content_type, artist_ids, and series_id —
        # same architectural rule as --all mode and as _lock_series_id.
        # A bare CLI invocation like 'curate -- detlev_joecker' was
        # previously curating known music artists as Hörspiele
        # because content_type from series.yaml was ignored, leaving
        # the agent to exclude every album as 'music, not Hörspiel'.
        entry = _lookup_catalog_entry(query)
        if entry is not None:
            existing: dict | None = None
            curation_path = CURATION_DIR / f"{entry.id}.json"
            if curation_path.exists():
                try:
                    existing = json.loads(curation_path.read_text())
                except (OSError, json.JSONDecodeError):
                    existing = None
            entry_is_music = _resolve_is_music(
                entry_content_type=entry.content_type,
                entry_has_pattern=bool(entry.episode_pattern),
                existing_content_type=(existing or {}).get("content_type"),
            )
            console.print(
                Panel(
                    f"Curating [bold]{entry.title}[/bold] with {model}\n"
                    f"Catalog id: {entry.id}\n"
                    f"Content type: "
                    f"{'music' if entry_is_music else 'hoerspiel'}\n"
                    f"Providers: {provider_names}",
                    title="lauschi-catalog curate",
                ),
            )
            if music and not entry_is_music:
                # User passed --music but yaml says hoerspiel. Yaml wins,
                # but tell them so the override silence isn't surprising.
                console.print(
                    "[yellow]Note: --music ignored — series.yaml has the "
                    "entry as hoerspiel. Edit series.yaml to change.[/yellow]",
                )
            path = _curate_one(
                entry.title, providers,
                model=model, timeout=timeout,
                series_id=entry.id,
                known_artist_ids=entry.all_artist_ids() or None,
                existing_curation=existing,
                is_music=entry_is_music,
                dry_run=dry_run,
            )
            if path is None and not dry_run:
                # Surface failure so pipeline scripts (catalog-pipeline-one)
                # abort instead of running review/verify on stale curation.
                raise SystemExit(1)
            return

        # New series not yet in series.yaml — trust the user's flags.
        console.print(
            Panel(
                f"Curating [bold]{query}[/bold] with {model}\n"
                f"Providers: {provider_names}\n"
                f"[dim]Not in series.yaml; treating as new "
                f"{'music artist' if music else 'Hörspiel series'}.[/dim]",
                title="lauschi-catalog curate",
            ),
        )
        path = _curate_one(query, providers, model=model, timeout=timeout, is_music=music, dry_run=dry_run)
        if path is None and not dry_run:
            raise SystemExit(1)
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

        entry_is_music = _resolve_is_music(
            entry_content_type=entry.content_type,
            entry_has_pattern=bool(entry.episode_pattern),
            existing_content_type=(existing or {}).get("content_type"),
        )
        path = _curate_one(
            entry.title, providers,
            model=model, timeout=timeout,
            series_id=entry.id,
            known_artist_ids=entry.all_artist_ids() or None,
            existing_curation=existing,
            is_music=entry_is_music,
            dry_run=dry_run,
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
