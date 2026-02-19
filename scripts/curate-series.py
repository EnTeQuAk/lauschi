#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai",
#   "pydantic>=2.0",
#   "requests",
#   "rich",
#   "ruamel.yaml",
# ]
# ///
"""
curate-series.py — AI-assisted series curation for the lauschi catalog.

Two independent models explore the Spotify API themselves (via tools), each
producing a CuratedSeries.  Disagreements are surfaced for human review.
Where both agree the result is written to series.yaml.

Usage
-----
  mise run catalog-curate -- "Die drei ???"
  mise run catalog-curate -- "Sternenschweif"
  mise run catalog-curate -- "TKKG" --models claude-sonnet-4-5,minimax-m2.5
  mise run catalog-curate -- "Yakari" --dry-run

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
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
from pydantic import BaseModel, Field, field_validator
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from rich import box
from rich.columns import Columns
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from ruamel.yaml import YAML

console = Console()

REPO_ROOT   = Path(__file__).parent.parent
CACHE_DIR   = REPO_ROOT / ".cache" / "spotify_artists"
SERIES_YAML = REPO_ROOT / "assets" / "catalog" / "series.yaml"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
# minimax-m2.5 excluded from default: opencode proxy 500s on prompt_tokens
# in tool-call responses. Use --models kimi-k2.5,minimax-m2.5 to retry later.
_DEFAULT_MODELS = "kimi-k2.5,glm-4.7"

# ── Spotify client ─────────────────────────────────────────────────────────────

class SpotifyClient:
    def __init__(self) -> None:
        cid  = os.environ.get("SPOTIFY_CLIENT_ID", "")
        csec = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
        if not cid or not csec:
            console.print("[red]SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET not set.[/]")
            sys.exit(1)
        r = requests.post(
            "https://accounts.spotify.com/api/token",
            data={"grant_type": "client_credentials",
                  "client_id": cid, "client_secret": csec},
            timeout=10,
        )
        r.raise_for_status()
        self._token = r.json()["access_token"]

    def _get(self, url: str, **params: Any) -> dict:
        while True:
            r = requests.get(
                url if url.startswith("http") else f"https://api.spotify.com/v1/{url}",
                headers={"Authorization": f"Bearer {self._token}"},
                params=params, timeout=20,
            )
            if r.status_code == 429:
                wait = int(r.headers.get("Retry-After", "2"))
                time.sleep(wait)
                continue
            r.raise_for_status()
            return r.json()

    def search_artists(self, query: str, limit: int = 8) -> list[dict]:
        data = self._get("search", q=query, type="artist", market="DE", limit=limit)
        return [
            {"id": a["id"], "name": a["name"],
             "followers": a["followers"]["total"],
             "genres": a.get("genres", [])}
            for a in data.get("artists", {}).get("items", [])
        ]

    def artist_albums(self, artist_id: str, use_cache: bool = True) -> list[dict]:
        cache = CACHE_DIR / f"{artist_id}.json"
        if use_cache and cache.exists():
            raw = json.loads(cache.read_text())
        else:
            raw = []
            url  = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
            p: dict = {"market": "DE", "limit": 50,
                       "album_type": "album,single,compilation"}
            while url:
                data = self._get(url, **p)
                raw.extend(data.get("items", []))
                url = data.get("next") or ""
                p   = {}
                time.sleep(0.08)
            cache.write_text(json.dumps(raw, ensure_ascii=False, indent=2))
        return [
            {"id": a["id"], "name": a["name"],
             "release_date": a.get("release_date", ""),
             "total_tracks": a.get("total_tracks", 0)}
            for a in raw
        ]

    def album_details(self, album_id: str) -> dict:
        cache = CACHE_DIR / f"album_{album_id}.json"
        if cache.exists():
            data = json.loads(cache.read_text())
        else:
            time.sleep(0.08)
            data = self._get(f"albums/{album_id}", market="DE")
            cache.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        return {
            "id":           data["id"],
            "name":         data["name"],
            "release_date": data.get("release_date", ""),
            "total_tracks": data.get("total_tracks", 0),
            "label":        data.get("label", ""),
            "tracks":       [t["name"] for t in
                             data.get("tracks", {}).get("items", [])],
        }


# ── Pydantic output models ─────────────────────────────────────────────────────

class AlbumDecision(BaseModel):
    spotify_album_id: str = Field(description="Spotify album ID (22-char base62)")
    include: bool         = Field(description="True = real episode; False = exclude")
    episode_num: int | None = Field(
        description="Episode number from the title. None if standalone or excluded.",
    )
    title: str = Field(description="Canonical album title (strip trailing noise like '(Hörspiel)')")
    exclude_reason: str | None = Field(
        default=None,
        description="Why excluded: 'box set', 're-release', 'compilation', 'spinoff', …",
    )

    @field_validator("spotify_album_id")
    @classmethod
    def _valid_id(cls, v: str) -> str:
        if not re.match(r"^[A-Za-z0-9]{22}$", v):
            raise ValueError(f"Not a valid Spotify album ID: {v!r}")
        return v


class CuratedSeries(BaseModel):
    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$",
                    description="snake_case ASCII, e.g. 'die_drei_fragezeichen'")
    title: str
    aliases: list[str]       = Field(default_factory=list)
    keywords: list[str]      = Field(
        default_factory=list,
        description=(
            "Lowercase words from the SERIES NAME that literally appear in album "
            "titles. Leave empty if the series name is absent from titles — "
            "artist_id matching handles those."
        ),
    )
    spotify_artist_ids: list[str]
    episode_pattern: str | None = Field(
        default=None,
        description=(
            "Python regex, ONE capture group for the episode number. "
            "Use alternation when the series uses multiple prefixes across its run, "
            "e.g. '(?:[Tt]eil|[Bb]and)\\\\s+(\\\\d+)'. "
            "Omit for standalone series."
        ),
    )
    albums: list[AlbumDecision] = Field(
        description="Decision for EVERY album fetched — included and excluded alike.",
    )
    curator_notes: str = Field(default="")

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | None) -> str | None:
        if v is None:
            return None
        try:
            c = re.compile(v)
        except re.error as e:
            raise ValueError(f"Invalid regex: {e}") from e
        if c.groups != 1:
            raise ValueError(f"Must have exactly 1 capture group, got {c.groups}")
        return v

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            key=lambda a: (a.episode_num or 999_999, a.title),
        )


# ── Agent factory ──────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are curating a DACH (Germany/Austria/Switzerland) children's Hörspiel series
catalog for "lauschi", a privacy-first kids audio player.

## Your job
Given a series name, use your tools to:
1. Search Spotify for the correct artist (pick the one that is the actual Hörspiel
   series, not a random band with a similar name).
2. Fetch the full discography for that artist.
3. For ambiguous albums (possible box sets, duplicates), call get_album_details.
4. Return a CuratedSeries with a decision for every album.

## What to include / exclude

Include: genuine individual episodes (usually 1–5 tracks, 20–60 min runtime).

Exclude:
- Box sets / compilations ("Folge 1-10", "Die besten 40", "Jubiläumsbox", "Box 1",
  "Best of"). Track count usually 10+.
- Duplicate episodes: same number released twice (original vs. "Neuproduktion" or
  "(ungekürzt)" unabridged). Keep the most recent or unabridged; exclude the other.
- Spinoffs you are not cataloging (note them in curator_notes).
- Audiobooks, soundtracks, sing-alongs.

## Episode numbers
Extract from dominant prefix: Folge N, Teil N, Episode N, Fall N, Band N, NNN/Title.
When the series switches prefix mid-run (e.g. "Teil 1-66" then "Band 67-68"),
use alternation: (?:[Tt]eil|[Bb]and)\\s+(\\d+)

## Keywords
Only if the series name literally appears in album titles. If titles are just
"Teil 5: Das goldene Schwert", leave keywords=[].

## Tools
- search_artists(query): find the right Spotify artist
- get_artist_albums(artist_id): full discography (cached)
- get_album_details(album_id): track list, release date, label — use selectively
"""


@dataclass
class Deps:
    spotify: SpotifyClient
    no_cache: bool = False


def build_agent(model_name: str, api_key: str) -> Agent[Deps, CuratedSeries]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model    = OpenAIChatModel(model_name, provider=provider)
    agent: Agent[Deps, CuratedSeries] = Agent(
        model,
        output_type=CuratedSeries,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def search_artists(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search Spotify for artists matching query. Returns id, name, followers, genres."""
        return ctx.deps.spotify.search_artists(query)

    @agent.tool
    def get_artist_albums(ctx: RunContext[Deps], artist_id: str) -> list[dict]:
        """Fetch full discography for a Spotify artist.
        Returns list of {id, name, release_date, total_tracks}."""
        return ctx.deps.spotify.artist_albums(artist_id, use_cache=not ctx.deps.no_cache)

    @agent.tool
    def get_album_details(ctx: RunContext[Deps], album_id: str) -> dict:
        """Full album details: release_date, total_tracks, track names, label.
        Use for ambiguous albums — box sets, suspected duplicates."""
        return ctx.deps.spotify.album_details(album_id)

    return agent


# ── Parallel dual-model curation ──────────────────────────────────────────────

async def run_one(model_name: str, api_key: str, query: str,
                  deps: Deps, timeout: int) -> CuratedSeries:
    agent  = build_agent(model_name, api_key)
    prompt = (
        f"Curate the DACH Hörspiel series: {query!r}.\n"
        "Start by calling search_artists to find the right Spotify artist, "
        "then get_artist_albums for the full discography. "
        "Use get_album_details selectively for ambiguous albums."
    )
    result = await asyncio.wait_for(agent.run(prompt, deps=deps), timeout=timeout)
    return result.output


async def run_dual(query: str, models: list[str], api_key: str,
                   deps: Deps, timeout: int) -> tuple[CuratedSeries | Exception, ...]:
    tasks = [run_one(m, api_key, query, deps, timeout) for m in models]
    return tuple(await asyncio.gather(*tasks, return_exceptions=True))


# ── Triage ─────────────────────────────────────────────────────────────────────

class Disagreement(BaseModel):
    album_id: str
    album_title: str
    issue: str  # e.g. "include: A=True B=False" or "episode_num: A=3 B=None"


def triage(a: CuratedSeries, b: CuratedSeries) -> list[Disagreement]:
    by_id_a = {x.spotify_album_id: x for x in a.albums}
    by_id_b = {x.spotify_album_id: x for x in b.albums}
    issues: list[Disagreement] = []

    all_ids = set(by_id_a) | set(by_id_b)
    for aid in sorted(all_ids):
        da = by_id_a.get(aid)
        db = by_id_b.get(aid)
        title = (da or db).title  # type: ignore[union-attr]
        if da is None:
            issues.append(Disagreement(album_id=aid, album_title=title,
                                       issue="missing from model A"))
            continue
        if db is None:
            issues.append(Disagreement(album_id=aid, album_title=title,
                                       issue="missing from model B"))
            continue
        if da.include != db.include:
            issues.append(Disagreement(album_id=aid, album_title=title,
                                       issue=f"include: A={da.include} B={db.include}"))
        elif da.include and da.episode_num != db.episode_num:
            issues.append(Disagreement(album_id=aid, album_title=title,
                                       issue=f"episode_num: A={da.episode_num} B={db.episode_num}"))

    if a.episode_pattern != b.episode_pattern:
        issues.append(Disagreement(album_id="—", album_title="(series-level)",
                                   issue=f"episode_pattern: A={a.episode_pattern!r} "
                                         f"B={b.episode_pattern!r}"))
    return issues


def merge_agreed(a: CuratedSeries, b: CuratedSeries,
                 disagreements: list[Disagreement]) -> CuratedSeries:
    """
    Build a merged result from the consensus of both models.

    Agreed decisions → taken as-is (high confidence).
    Disputed albums  → kept in output but flagged in curator_notes for human review.
    Series-level fields (id, title, pattern) → prefer A; flag if different.
    """
    disputed_ids = {d.album_id for d in disagreements}

    by_id_b = {x.spotify_album_id: x for x in b.albums}
    merged_albums: list[AlbumDecision] = []

    for ad in a.albums:
        if ad.spotify_album_id not in disputed_ids:
            merged_albums.append(ad)   # consensus — keep as-is
        else:
            # Keep A's decision but annotate the title so it stands out in YAML
            merged_albums.append(ad.model_copy(
                update={"title": f"[DISPUTED] {ad.title}"}
            ))

    # Albums only in B (missing from A) — add them as disputed
    seen = {x.spotify_album_id for x in a.albums}
    for bd in b.albums:
        if bd.spotify_album_id not in seen:
            merged_albums.append(bd.model_copy(
                update={"title": f"[DISPUTED] {bd.title}"}
            ))

    dispute_lines = [f"  {d.album_title} ({d.album_id}): {d.issue}"
                     for d in disagreements]
    notes = ("DISPUTED — review [DISPUTED] entries before committing:\n"
             + "\n".join(dispute_lines)) if disagreements else a.curator_notes

    return a.model_copy(update={"albums": merged_albums, "curator_notes": notes})


# ── Tiebreaker ────────────────────────────────────────────────────────────────

class TiebreakerResult(BaseModel):
    decisions: list[AlbumDecision] = Field(
        description="One decision per disputed album. Cover every album_id provided.",
    )
    reasoning: str = Field(description="Brief explanation of each decision.")


_TIEBREAKER_SYSTEM = """\
You are the final arbiter for a DACH children's Hörspiel catalog curation.
Two AI models disagreed on certain Spotify albums. For each disputed album,
make the definitive call: include (real episode) or exclude (box set, duplicate, etc.).
Use get_album_details if the title alone is ambiguous.
"""


async def run_tiebreaker(disputed: list[Disagreement],
                         a: CuratedSeries, b: CuratedSeries,
                         model_name: str, api_key: str,
                         deps: Deps, timeout: int) -> TiebreakerResult:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    tb_agent: Agent[Deps, TiebreakerResult] = Agent(
        OpenAIChatModel(model_name, provider=provider),
        output_type=TiebreakerResult,
        system_prompt=_TIEBREAKER_SYSTEM,
        retries=2,
    )

    @tb_agent.tool
    def get_album_details(ctx: RunContext[Deps], album_id: str) -> dict:
        """Full album details: release_date, total_tracks, track names, label."""
        return ctx.deps.spotify.album_details(album_id)

    by_id_a = {x.spotify_album_id: x for x in a.albums}
    by_id_b = {x.spotify_album_id: x for x in b.albums}

    lines = [f"Series: {a.title}", "", "Disputed albums:"]
    for d in disputed:
        da = by_id_a.get(d.album_id)
        db = by_id_b.get(d.album_id)
        lines.append(f"\n  album_id: {d.album_id}")
        lines.append(f"  title:    {d.album_title}")
        lines.append(f"  issue:    {d.issue}")
        if da:
            lines.append(f"  model_A:  include={da.include} episode_num={da.episode_num}")
        if db:
            lines.append(f"  model_B:  include={db.include} episode_num={db.episode_num}")

    prompt = "\n".join(lines) + "\n\nGive a final decision for each album_id above."
    result = await asyncio.wait_for(tb_agent.run(prompt, deps=deps), timeout=timeout)
    return result.output


def apply_tiebreaker(merged: CuratedSeries,
                     tb: TiebreakerResult) -> CuratedSeries:
    """Replace [DISPUTED] album decisions with tiebreaker verdicts."""
    overrides = {d.spotify_album_id: d for d in tb.decisions}
    new_albums = []
    for alb in merged.albums:
        if alb.spotify_album_id in overrides:
            verdict = overrides[alb.spotify_album_id]
            # Strip [DISPUTED] prefix from title
            clean_title = alb.title.removeprefix("[DISPUTED] ")
            new_albums.append(verdict.model_copy(update={"title": clean_title}))
        else:
            new_albums.append(alb)
    notes = f"Tiebreaker ({tb.reasoning[:200]})" if merged.curator_notes else ""
    return merged.model_copy(update={"albums": new_albums, "curator_notes": notes})


# ── Display ────────────────────────────────────────────────────────────────────

def print_series(series: CuratedSeries, title: str) -> None:
    inc = series.included()
    exc = [x for x in series.albums if not x.include]
    t   = Table(box=box.SIMPLE, title=title, min_width=60)
    t.add_column("Ep",  width=4, justify="right")
    t.add_column("Title", min_width=38)
    t.add_column("ID",  width=24)
    for ep in inc[:12]:
        t.add_row(str(ep.episode_num) if ep.episode_num else "—",
                  ep.title[:38], ep.spotify_album_id)
    if len(inc) > 12:
        t.add_row("…", f"({len(inc)-12} more)", "")
    console.print(t)
    console.print(f"[dim]Excluded: {len(exc)} · Pattern: {series.episode_pattern or 'none'}[/]")


def print_disagreements(issues: list[Disagreement]) -> None:
    if not issues:
        console.print("[green]✓ Both models agree.[/]")
        return
    t = Table(box=box.SIMPLE, title=f"[yellow]{len(issues)} disagreements[/]")
    t.add_column("Album", min_width=38)
    t.add_column("Issue", min_width=30)
    for d in issues:
        t.add_row(d.album_title[:38], d.issue)
    console.print(t)


# ── YAML ───────────────────────────────────────────────────────────────────────

def to_yaml_dict(series: CuratedSeries) -> dict:
    d: dict = {"id": series.id, "title": series.title}
    if series.aliases:
        d["aliases"] = series.aliases
    if series.keywords:
        d["keywords"] = series.keywords
    d["spotify_artist_ids"] = series.spotify_artist_ids
    if series.episode_pattern:
        d["episode_pattern"] = series.episode_pattern
    eps = series.included()
    if eps:
        d["albums"] = [
            ({"id": e.spotify_album_id, "episode": e.episode_num, "title": e.title}
             if e.episode_num is not None
             else {"id": e.spotify_album_id, "title": e.title})
            for e in eps
        ]
    if series.curator_notes:
        d["_curator_notes"] = series.curator_notes
    return d


def write_yaml(series: CuratedSeries, dry_run: bool) -> None:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False
    yaml.width = 100

    entry = to_yaml_dict(series)

    if dry_run:
        import io
        buf = io.StringIO()
        yaml.dump([entry], buf)
        console.print(Panel(buf.getvalue(), title="series.yaml (dry run)",
                            border_style="yellow"))
        return

    with SERIES_YAML.open(encoding="utf-8") as f:
        data = yaml.load(f) or {}
    series_list: list = data.get("series", [])
    idx = next((i for i, s in enumerate(series_list)
                if s.get("id") == series.id), None)
    if idx is not None:
        console.print(f"[yellow]Replacing existing entry for {series.id}[/]")
        series_list[idx] = entry
    else:
        series_list.append(entry)
        console.print(f"[green]Appended {series.id} to series.yaml[/]")
    with SERIES_YAML.open("w", encoding="utf-8") as f:
        yaml.dump(data, f)


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="AI-curated series.yaml — two independent models, triage disagreements.",
        epilog='Example: mise run catalog-curate -- "Sternenschweif"',
    )
    ap.add_argument("query", help="Series name to curate")
    ap.add_argument(
        "--models", default=_DEFAULT_MODELS,
        help=f"Comma-separated pair of opencode models (default: {_DEFAULT_MODELS!r}). "
             "Reliable cheap pair: kimi-k2.5,glm-4.7. "
             "Higher quality: kimi-k2.5,claude-sonnet-4-6",
    )
    ap.add_argument("--no-cache",  action="store_true", help="Bypass Spotify cache")
    ap.add_argument("--dry-run",   action="store_true",
                    help="Print YAML, don't write to series.yaml")
    ap.add_argument("--json-out",  metavar="FILE",
                    help="Save both raw CuratedSeries objects as JSON")
    ap.add_argument("--timeout",   type=int, default=300,
                    help="Per-model timeout in seconds (default: 300)")
    ap.add_argument("--tiebreaker", metavar="MODEL", default=None,
                    help="Model to resolve disagreements automatically "
                         "(e.g. claude-sonnet-4-5). Without this, disputes "
                         "are flagged in _curator_notes for human review.")
    args = ap.parse_args()

    model_list = [m.strip() for m in args.models.split(",")]
    if len(model_list) != 2:
        console.print("[red]--models requires exactly two comma-separated model names.[/]")
        sys.exit(1)

    api_key = os.environ.get("OPENCODE_API_KEY")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set — add to .env[/]")
        sys.exit(1)

    spotify = SpotifyClient()
    deps    = Deps(spotify=spotify, no_cache=args.no_cache)

    console.print(Panel(
        f"[bold]{args.query}[/]\n"
        f"Models: {model_list[0]}  ·  {model_list[1]}\n"
        f"Timeout: {args.timeout}s per model",
        title="🎧 lauschi series curator",
    ))

    # ── Run both models in parallel ────────────────────────────────────────────
    results = asyncio.run(run_dual(args.query, model_list, api_key, deps, args.timeout))
    a_raw, b_raw = results

    # Handle errors
    errors = [(model_list[i], results[i]) for i in range(2)
              if isinstance(results[i], Exception)]
    if errors:
        for name, err in errors:
            console.print(f"[red]{name} failed:[/] {err}")
        if len(errors) == 2:
            sys.exit(1)

    a: CuratedSeries = a_raw if not isinstance(a_raw, Exception) else b_raw  # type: ignore[assignment]
    b: CuratedSeries = b_raw if not isinstance(b_raw, Exception) else a_raw  # type: ignore[assignment]

    # ── Show both outputs side by side ─────────────────────────────────────────
    console.rule("Results")
    if not isinstance(a_raw, Exception):
        print_series(a, f"[cyan]{model_list[0]}[/]")
    if not isinstance(b_raw, Exception) and b is not a:
        print_series(b, f"[magenta]{model_list[1]}[/]")

    # ── Triage disagreements ───────────────────────────────────────────────────
    console.rule("Triage")
    issues: list[Disagreement] = []
    if a is not b:  # both succeeded
        issues = triage(a, b)
        print_disagreements(issues)

    merged = merge_agreed(a, b, issues)

    # ── Tiebreaker for disputes ────────────────────────────────────────────────
    album_disputes = [d for d in issues if d.album_id != "—"]
    if album_disputes and args.tiebreaker:
        console.rule(f"Tiebreaker: {args.tiebreaker}")
        try:
            tb = asyncio.run(run_tiebreaker(
                album_disputes, a, b, args.tiebreaker, api_key, deps, args.timeout
            ))
            console.print(f"[green]Tiebreaker resolved {len(tb.decisions)} album(s).[/]")
            console.print(f"[dim]{tb.reasoning[:300]}[/]")
            merged = apply_tiebreaker(merged, tb)
        except Exception as e:
            console.print(f"[red]Tiebreaker failed:[/] {e}")
            console.print("[yellow]Falling back to flagged disputes in YAML.[/]")
    elif album_disputes and not args.tiebreaker:
        console.print(
            f"[dim]Tip: add --tiebreaker claude-sonnet-4-5 to auto-resolve "
            f"{len(album_disputes)} dispute(s).[/]"
        )

    # ── Optionally save raw JSON ───────────────────────────────────────────────
    if args.json_out:
        out = {"models": model_list,
               "a": a.model_dump() if not isinstance(a_raw, Exception) else None,
               "b": b.model_dump() if not isinstance(b_raw, Exception) else None,
               "disagreements": [d.model_dump() for d in issues]}
        Path(args.json_out).write_text(json.dumps(out, indent=2, ensure_ascii=False))
        console.print(f"[dim]JSON saved → {args.json_out}[/]")

    # ── Write (or dry-run) ─────────────────────────────────────────────────────
    remaining_disputes = [a for a in merged.albums if a.title.startswith("[DISPUTED]")]
    if remaining_disputes:
        console.print(f"\n[yellow]{len(remaining_disputes)} unresolved dispute(s) — "
                      "search [DISPUTED] in the YAML before committing.[/]")
    else:
        console.print("\n[green]✓ Clean output — no unresolved disputes.[/]")
    write_yaml(merged, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
