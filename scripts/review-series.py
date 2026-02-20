#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai>=1.62.0",
#   "pydantic>=2.0",
#   "requests",
#   "rich",
# ]
# ///
"""
review-series.py — AI-assisted review of curated series data.

Reads a curation JSON, analyzes it for issues (sub-series duplicates, gaps,
era variants), and writes non-destructive review decisions: overrides to
exclude, additions for gaps, and split proposals for content that belongs
in a separate series entry.

All changes go to the `review` block — the original AI curation is preserved.

Usage
-----
  mise exec -- uv run scripts/review-series.py sternenschweif
  mise exec -- uv run scripts/review-series.py --all
  mise exec -- uv run scripts/review-series.py --all --timeout 600
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import requests
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.messages import ModelResponse, TextPart, ThinkingPart
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.table import Table

console = Console()

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL     = "kimi-k2.5"
_MAX_RETRIES       = 3
_RETRY_DELAY       = 5


# ── Spotify helpers ────────────────────────────────────────────────────────────

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

    def search_albums(self, query: str, limit: int = 10) -> list[dict]:
        r = requests.get(
            "https://api.spotify.com/v1/search",
            headers={"Authorization": f"Bearer {self._token}"},
            params={"q": query, "type": "album", "market": "DE", "limit": limit},
            timeout=10,
        )
        r.raise_for_status()
        return [
            {"id": a["id"], "name": a["name"],
             "total_tracks": a.get("total_tracks", 0),
             "artists": ", ".join(art["name"] for art in a.get("artists", []))}
            for a in r.json().get("albums", {}).get("items", [])
        ]

    def album_details(self, album_id: str, *, include_tracks: bool = False) -> dict | None:
        r = requests.get(
            f"https://api.spotify.com/v1/albums/{album_id}",
            headers={"Authorization": f"Bearer {self._token}"},
            params={"market": "DE"},
            timeout=10,
        )
        if not r.ok:
            return None
        data = r.json()
        result: dict[str, Any] = {
            "id": data["id"], "name": data["name"],
            "total_tracks": data.get("total_tracks", 0),
            "release_date": data.get("release_date", ""),
        }
        if include_tracks:
            tracks = data.get("tracks", {}).get("items", [])
            result["tracks"] = [
                {"name": t["name"], "duration_ms": t.get("duration_ms", 0)}
                for t in tracks
            ]
        return result


# ── Output models ──────────────────────────────────────────────────────────────

class ReviewOverride(BaseModel):
    album_id: str
    action: str = Field(description="'exclude' or 'include'")
    reason: str = ""


class SplitProposal(BaseModel):
    new_id: str = Field(
        pattern=r"^[a-z][a-z0-9_]*$",
        description="ID for the new series, e.g. 'biene_maja_klassik'",
    )
    new_title: str = Field(description="Display title, e.g. 'Die Biene Maja (Klassik)'")
    album_ids: list[str] = Field(description="Spotify album IDs to move to the new series")
    reason: str = ""


class ReviewResult(BaseModel):
    series_id: str
    overrides: list[ReviewOverride] = Field(default_factory=list)
    splits: list[SplitProposal] = Field(default_factory=list)
    added_albums: list[str] = Field(
        default_factory=list,
        description="Spotify album IDs added to fill gaps",
    )
    notes: str = Field(default="", description="Reviewer notes for human follow-up")


# ── Agent ──────────────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are reviewing AI-curated DACH children's Hörspiel series data for "lauschi",
a privacy-first kids audio player that targets kids aged 3-14.

You receive a series with all its albums (included and excluded) and must make
review decisions. Every change is non-destructive — the original AI curation
is preserved and your decisions are layered on top.

## Your goal

Look at the albums and think about what a parent browsing the app would expect.
A series entry in lauschi should feel like ONE coherent thing to listen to.
When you see albums that a parent would think of as a different show, a different
product, or a different era — those should be their own series, not mixed in.

## Three decisions you can make

1. **Keep**: Album belongs here. No action needed.

2. **Exclude**: Album is not useful content — box sets, compilations, best-of
   collections, soundtracks, Lieder albums, Kopfhörer remixes, or true
   duplicates of an already-included episode. Use `exclude_album`.

3. **Split**: Album is good content but it's a different product that deserves
   its own series entry. Use `propose_split` to group related albums under a
   new series ID and title.

   Think about it from a parent's perspective: would they see these as the same
   show or a different one? Different voice cast, different production era,
   different target age, different branding — these are signals that it's a
   separate product. Pick a title and ID that makes sense for the split series.

## Verifying before excluding

Before excluding an album as a "duplicate", verify it actually IS the same
content. Use `album_details` to compare release dates, track counts, and track
names. If you need cultural context (is this a standalone special? a different
era?), use `wikipedia_lookup` first — German Wikipedia has excellent Hörspiel
coverage. Fall back to `web_search` only if Wikipedia doesn't have it.

You have a maximum of 2 lookups total (wikipedia + web combined). One lookup
per question — if it doesn't answer it, flag in `notes` and move on.

If you're not sure whether something is a duplicate or distinct content,
flag it in `notes` for human review instead of excluding it. Wrong excludes
are much worse than missed excludes — a human can easily exclude in the TUI,
but wrong excludes erode trust in the pipeline.

## Gap-filling

If there are gaps in episode numbering, try ONE search to find each missing
episode. If the first search doesn't return an obvious match, the episode is
probably not on Spotify. Note it and move on. Do NOT retry the same gap with
different query variations — Spotify's search is simple and rephrasing won't
help. Maximum 2 search attempts per gap.

## Rules

- Do NOT remove albums. Exclude or split instead.
- The `show_series` tool shows everything: included, excluded, gaps, duplicates.
- For series with no issues, return an empty ReviewResult.
- Flag anything you're unsure about in `notes` for human review.
- Be efficient. Don't loop on searches that aren't finding results.
"""


@dataclass
class Deps:
    spotify: SpotifyClient
    series_id: str
    curation: dict
    # In-memory tracking
    added_albums: list[dict] = field(default_factory=list)

    _MAX_SEARCHES: int = 30

    _MAX_LOOKUPS: int = 2

    def __post_init__(self) -> None:
        self._search_cache: dict[str, list[dict]] = {}
        self._search_count: int = 0
        self._lookup_count: int = 0


def _analyze_series(curation: dict) -> dict[str, Any]:
    """Pre-compute issues for the system prompt context."""
    series = curation["series"]
    albums = series.get("albums", [])
    included = [a for a in albums if a.get("include")]
    excluded = [a for a in albums if not a.get("include")]
    pattern = series.get("episode_pattern")

    info: dict[str, Any] = {
        "id": series["id"],
        "title": series.get("title", ""),
        "artist_ids": series.get("spotify_artist_ids", []),
        "pattern": pattern,
        "total_albums": len(albums),
        "included": len(included),
        "excluded": len(excluded),
    }

    eps = sorted(a.get("episode_num") for a in included
                 if a.get("episode_num") is not None)
    if eps:
        info["episode_range"] = f"{min(eps)}-{max(eps)}"
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        if gaps:
            info["gaps"] = gaps

        counts = Counter(a.get("episode_num") for a in included
                         if a.get("episode_num") is not None)
        dupes = sorted(ep for ep, n in counts.items() if n > 1)
        if dupes:
            dupe_details = []
            for ep in dupes:
                entries = [a for a in included if a.get("episode_num") == ep]
                dupe_details.append({
                    "episode": ep,
                    "albums": [{"id": a["spotify_album_id"], "title": a["title"]}
                               for a in entries],
                })
            info["duplicates"] = dupe_details

    return info


def build_agent(model_name: str, api_key: str) -> Agent[Deps, ReviewResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)
    agent: Agent[Deps, ReviewResult] = Agent(
        model,
        output_type=ReviewResult,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def show_series(ctx: RunContext[Deps]) -> dict:
        """Show the full series state: all albums (included + excluded),
        episode gaps, duplicates, artist IDs, and pattern."""
        series = ctx.deps.curation["series"]
        albums = series.get("albums", [])

        included = sorted(
            [a for a in albums if a.get("include")],
            key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
        )
        excluded = sorted(
            [a for a in albums if not a.get("include")],
            key=lambda a: a["title"],
        )

        analysis = _analyze_series(ctx.deps.curation)

        console.print(f"  [dim]📋 show_series() → {len(included)} included, "
                      f"{len(excluded)} excluded[/]")
        return {
            "analysis": analysis,
            "included": [
                {"id": a["spotify_album_id"], "title": a["title"],
                 "episode": a.get("episode_num")}
                for a in included
            ],
            "excluded": [
                {"id": a["spotify_album_id"], "title": a["title"],
                 "reason": a.get("exclude_reason", "")}
                for a in excluded
            ],
        }

    @agent.tool
    def search_spotify(ctx: RunContext[Deps], query: str) -> list[dict] | str:
        """Search Spotify for albums. Use to find missing episodes for gap-filling.
        Try ONE simple search per gap. If it doesn't match, note it and move on."""
        if query in ctx.deps._search_cache:
            console.print(f"  [dim]🔍 search_spotify({query!r}) → (cached)[/]")
            return ctx.deps._search_cache[query]
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            console.print(f"  [dim]🔍 search_spotify({query!r}) → search limit reached[/]")
            return "Search limit reached. Note remaining gaps and move on."
        ctx.deps._search_count += 1
        results = ctx.deps.spotify.search_albums(query)
        ctx.deps._search_cache[query] = results
        console.print(f"  [dim]🔍 search_spotify({query!r}) → {len(results)} results[/]")
        return results

    @agent.tool
    def album_details(ctx: RunContext[Deps], album_id: str) -> dict | str:
        """Get detailed info about a Spotify album: release date, track count,
        and track names. Use this to verify whether two albums are actually
        the same content or different releases."""
        info = ctx.deps.spotify.album_details(album_id, include_tracks=True)
        if not info:
            console.print(f"  [dim]📀 album_details({album_id[:8]}…) → not found[/]")
            return f"Not found: {album_id}"
        console.print(f"  [dim]📀 album_details({album_id[:8]}…) → "
                      f"{info['name']} ({info['release_date']}, "
                      f"{info['total_tracks']} tracks)[/]")
        return info

    @agent.tool
    def wikipedia_lookup(ctx: RunContext[Deps], query: str) -> str:
        """Look up a series, album, or Hörspiel on German Wikipedia. Returns
        the article extract if found. Use this to verify episode lists,
        release history, and whether something is a standalone special or
        part of a series. Prefer this over web_search for factual info."""
        if ctx.deps._lookup_count >= ctx.deps._MAX_LOOKUPS:
            console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → limit reached[/]")
            return "Lookup limit reached. Flag uncertainty in notes and move on."
        ctx.deps._lookup_count += 1
        try:
            # Search for the best matching article
            headers = {"User-Agent": "lauschi-catalog-review/1.0 "
                       "(https://github.com/EnTeQuAk/lauschi)"}
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={"action": "query", "list": "search",
                        "srsearch": query, "srlimit": 3,
                        "format": "json"},
                timeout=10,
            )
            r.raise_for_status()
            hits = r.json().get("query", {}).get("search", [])
            if not hits:
                console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → no article[/]")
                return "No Wikipedia article found."
            # Fetch the extract of the top result
            title = hits[0]["title"]
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={"action": "query", "titles": title,
                        "prop": "extracts", "exintro": False,
                        "explaintext": True, "exchars": 3000,
                        "format": "json"},
                timeout=10,
            )
            r.raise_for_status()
            pages = r.json().get("query", {}).get("pages", {})
            extract = next(iter(pages.values())).get("extract", "")
            console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → {title}[/]")
            return f"Wikipedia: {title}\n\n{extract}"
        except Exception as e:
            console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → error: {e}[/]")
            return f"Wikipedia lookup failed: {e}"

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> str:
        """Search the web as a fallback when Wikipedia doesn't have what you
        need. Shares the lookup limit with wikipedia_lookup."""
        if ctx.deps._lookup_count >= ctx.deps._MAX_LOOKUPS:
            console.print(f"  [dim]🌐 web_search({query!r}) → limit reached[/]")
            return "Lookup limit reached. Flag uncertainty in notes and move on."
        ctx.deps._lookup_count += 1
        brave_key = os.environ.get("BRAVE_API_KEY", "")
        if not brave_key:
            console.print(f"  [dim]🌐 web_search({query!r}) → no API key[/]")
            return "BRAVE_API_KEY not set. Cannot search the web."
        try:
            r = requests.get(
                "https://api.search.brave.com/res/v1/web/search",
                headers={"X-Subscription-Token": brave_key,
                         "Accept": "application/json"},
                params={"q": query, "count": 5, "country": "DE",
                        "search_lang": "de"},
                timeout=10,
            )
            r.raise_for_status()
            results = r.json().get("web", {}).get("results", [])
            snippets = []
            for item in results[:5]:
                title = item.get("title", "")
                snippet = item.get("description", "")
                snippets.append(f"- {title}: {snippet}")
            summary = "\n".join(snippets) if snippets else "No results found."
            console.print(f"  [dim]🌐 web_search({query!r}) → "
                          f"{len(results)} results[/]")
            return summary
        except Exception as e:
            console.print(f"  [dim]🌐 web_search({query!r}) → error: {e}[/]")
            return f"Search failed: {e}"

    @agent.tool
    def add_album(ctx: RunContext[Deps], album_id: str) -> str:
        """Add a missing album to the series. Fetches details from Spotify
        and extracts the episode number from the series pattern."""
        # Check duplicate
        existing = {a["spotify_album_id"]
                    for a in ctx.deps.curation["series"].get("albums", [])}
        if album_id in existing:
            console.print(f"  [dim]➕ add_album({album_id[:8]}…) → already exists[/]")
            return f"Already exists: {album_id}"

        info = ctx.deps.spotify.album_details(album_id)
        if not info:
            console.print(f"  [dim]➕ add_album({album_id[:8]}…) → not found[/]")
            return f"Not found: {album_id}"

        pattern = ctx.deps.curation["series"].get("episode_pattern")
        episode_num = None
        if pattern:
            m = re.search(pattern, info["name"])
            if m and m.groups():
                try:
                    episode_num = int(m.group(1))
                except (ValueError, IndexError):
                    pass

        new_album = {
            "spotify_album_id": album_id,
            "include": True,
            "episode_num": episode_num,
            "title": info["name"],
            "exclude_reason": None,
        }
        ctx.deps.added_albums.append(new_album)
        ep_str = f" (episode {episode_num})" if episode_num else ""
        console.print(f"  [dim]➕ add_album({album_id[:8]}…) → {info['name']}{ep_str}[/]")
        return f"Added: {info['name']}{ep_str}"

    return agent


# ── Run ────────────────────────────────────────────────────────────────────────

def _build_prompt(curation: dict) -> str:
    analysis = _analyze_series(curation)
    series = curation["series"]

    lines = [
        f"Review the series: **{series['title']}** (`{series['id']}`)",
        f"Pattern: `{series.get('episode_pattern', 'none')}`",
        f"Artists: {', '.join(series.get('spotify_artist_ids', []))}",
        f"Albums: {analysis['included']} included, {analysis['excluded']} excluded",
    ]

    if analysis.get("gaps"):
        lines.append(f"Gaps: {analysis['gaps']}")
    if analysis.get("duplicates"):
        lines.append(f"Duplicate episodes: {len(analysis['duplicates'])} "
                     f"(episodes {[d['episode'] for d in analysis['duplicates']]})")

    lines.append("")
    lines.append("Call `show_series` to see all albums, then make your decisions.")
    lines.append("If there are no issues, return an empty ReviewResult.")

    return "\n".join(lines)


async def review_one(
    model_name: str, api_key: str, series_id: str,
    spotify: SpotifyClient, timeout: int,
) -> tuple[ReviewResult, list] | None:
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Not found: {path}[/]")
        return None

    curation = json.loads(path.read_text())

    # Skip rejected stubs
    if curation.get("review", {}).get("status") == "rejected":
        console.print(f"[dim]Skipping {series_id} (rejected stub)[/]")
        return None

    # Quick check: any issues?
    analysis = _analyze_series(curation)
    has_issues = bool(
        analysis.get("gaps")
        or analysis.get("duplicates")
    )

    if not has_issues:
        console.print(f"[dim]  No issues found for {series_id}[/]")
        return ReviewResult(series_id=series_id), []

    deps = Deps(spotify=spotify, series_id=series_id, curation=curation)
    agent = build_agent(model_name, api_key)
    prompt = _build_prompt(curation)

    async def _run() -> tuple[ReviewResult, list]:
        async with agent.iter(
            prompt, deps=deps,
            usage_limits=UsageLimits(request_limit=100),
        ) as run:
            async for node in run:
                if not hasattr(node, 'model_response'):
                    continue
                for part in node.model_response.parts:
                    text = getattr(part, 'content', None)
                    if not isinstance(text, str) or len(text.strip()) <= 80:
                        continue
                    kind = getattr(part, 'part_kind', '')
                    label = "💭 reasoning" if kind == "thinking" else "💭"
                    console.print(Panel(
                        Markdown(text.strip()), border_style="dim",
                        title=label, padding=(0, 1),
                    ))
            result = run.result.output
            result.added_albums = [a["spotify_album_id"] for a in deps.added_albums]
            return result, run.result.all_messages()

    last_err: Exception | None = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            return await asyncio.wait_for(_run(), timeout=timeout)
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


def apply_review(series_id: str, result: ReviewResult) -> None:
    """Write review decisions to the curation JSON (non-destructive)."""
    path = CURATION_DIR / f"{series_id}.json"
    data = json.loads(path.read_text())

    review = data.setdefault("review", {})
    review["reviewed_at"] = datetime.now(tz=UTC).isoformat()
    review["reviewed_by"] = "review-series.py"

    # Merge overrides (don't duplicate)
    existing_overrides = {o["album_id"]: o for o in review.get("overrides", [])}
    for ov in result.overrides:
        existing_overrides[ov.album_id] = ov.model_dump()
    review["overrides"] = list(existing_overrides.values())

    # Set splits
    if result.splits:
        review["splits"] = [s.model_dump() for s in result.splits]

    # Add new albums to the base data (these are genuinely new, not overrides)
    if result.added_albums:
        # Load the added album details we stored during the run
        existing_ids = {a["spotify_album_id"]
                        for a in data["series"].get("albums", [])}
        spotify = SpotifyClient()
        pattern = data["series"].get("episode_pattern")
        for album_id in result.added_albums:
            if album_id in existing_ids:
                continue
            info = spotify.album_details(album_id)
            if not info:
                continue
            episode_num = None
            if pattern:
                m = re.search(pattern, info["name"])
                if m and m.groups():
                    try:
                        episode_num = int(m.group(1))
                    except (ValueError, IndexError):
                        pass
            data["series"]["albums"].append({
                "spotify_album_id": album_id,
                "include": True,
                "episode_num": episode_num,
                "title": info["name"],
                "exclude_reason": None,
            })

    # Notes
    if result.notes:
        existing_notes = review.get("notes", "")
        if existing_notes:
            review["notes"] = f"{existing_notes}\n{result.notes}"
        else:
            review["notes"] = result.notes

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


# ── Display ────────────────────────────────────────────────────────────────────

def print_reasoning(messages: list) -> None:
    """Print the model's initial assessment and final review reasoning.

    Skips short fragments (tool call confirmations) — only shows the
    substantive thinking at the start and end.
    """
    texts: list[str] = []
    for msg in messages:
        if not isinstance(msg, ModelResponse):
            continue
        for part in msg.parts:
            if isinstance(part, TextPart) and part.content.strip():
                text = part.content.strip()
                # Skip short tool-call acknowledgments
                if len(text) > 80:
                    texts.append(text)
    if not texts:
        return
    # First substantive block = initial assessment, last = final review
    to_show = [texts[0]] if len(texts) == 1 else [texts[0], texts[-1]]
    for text in to_show:
        console.print(f"  [dim italic]💭 {text}[/]")


def print_result(result: ReviewResult) -> None:
    overrides = result.overrides
    splits = result.splits
    added = result.added_albums

    if not overrides and not splits and not added and not result.notes:
        console.print("[dim]  No changes needed.[/]")
        return

    lines = []
    if overrides:
        excludes = [o for o in overrides if o.action == "exclude"]
        includes = [o for o in overrides if o.action == "include"]
        if excludes:
            lines.append(f"❌ {len(excludes)} excluded")
        if includes:
            lines.append(f"✅ {len(includes)} re-included")
    if splits:
        for s in splits:
            lines.append(f"✂️  Split → {s.new_title} ({s.new_id}): "
                         f"{len(s.album_ids)} albums")
    if added:
        lines.append(f"➕ {len(added)} added")
    if result.notes:
        lines.append(f"📝 {result.notes}")

    console.print(Panel(
        Markdown("\n".join(lines)),
        title=f"Review: {result.series_id}",
        border_style="cyan",
    ))


# ── Main ───────────────────────────────────────────────────────────────────────

async def main_async(args: argparse.Namespace) -> None:
    api_key = os.environ.get("OPENCODE_API_KEY")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set — add to .env[/]")
        sys.exit(1)

    spotify = SpotifyClient()

    if args.all:
        series_ids = sorted(
            p.stem for p in CURATION_DIR.glob("*.json")
        )
    else:
        series_ids = [args.series_id]

    total_overrides = 0
    total_splits = 0
    total_added = 0

    for series_id in series_ids:
        console.print(Panel(
            f"[bold]{series_id}[/]\nModel: {args.model} · Timeout: {args.timeout}s",
            title="🔍 reviewing",
        ))

        try:
            outcome = await review_one(
                args.model, api_key, series_id, spotify, args.timeout,
            )
        except Exception as e:
            console.print(f"[red]  Failed: {e}[/]")
            continue

        if outcome is None:
            continue

        result, _messages = outcome
        print_result(result)

        if result.overrides or result.splits or result.added_albums:
            apply_review(series_id, result)
            console.print(f"[dim]  Saved → {CURATION_DIR / series_id}.json[/]")

        total_overrides += len(result.overrides)
        total_splits += len(result.splits)
        total_added += len(result.added_albums)

    if len(series_ids) > 1:
        console.print(Panel(
            f"Overrides: {total_overrides} · Splits: {total_splits} · "
            f"Added: {total_added}",
            title="Summary",
            border_style="green",
        ))


def main() -> None:
    ap = argparse.ArgumentParser(
        description="AI-assisted review of curated series data.",
    )
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("series_id", nargs="?", help="Series ID to review")
    group.add_argument("--all", action="store_true", help="Review all series")
    ap.add_argument("--model", default=_DEFAULT_MODEL)
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
