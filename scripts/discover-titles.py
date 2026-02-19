#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests", "rich"]
# ///
"""
discover-titles.py — Spotify artist/series discovery for the lauschi catalog.

Searches for an artist, fetches their full discography, analyses episode-number
patterns, and optionally calls `pi` to produce a ready-to-paste series.yaml
entry.

Usage
-----
  uv run scripts/discover-titles.py "Sternenschweif"
  uv run scripts/discover-titles.py "Löwenzahn" --ai
  uv run scripts/discover-titles.py --artist-id 79iLUmzekfn37nPHuM09uq
  uv run scripts/discover-titles.py "TKKG" --ai --model claude-sonnet-4-5
  uv run scripts/discover-titles.py "Yakari" --pick 0   # auto-pick first result

Credentials
-----------
  Reads SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET from the environment
  (or from .env in the lauschi project root via mise / direnv).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

import requests
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()

# ── Paths ─────────────────────────────────────────────────────────────────────

REPO_ROOT   = Path(__file__).parent.parent
CACHE_DIR   = REPO_ROOT / ".cache" / "spotify_artists"
CACHE_DIR.mkdir(parents=True, exist_ok=True)

# ── Spotify auth ───────────────────────────────────────────────────────────────

def _token() -> str:
    client_id     = os.environ.get("SPOTIFY_CLIENT_ID", "")
    client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        console.print("[red]SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET not set.[/]")
        sys.exit(1)
    r = requests.post(
        "https://accounts.spotify.com/api/token",
        data={"grant_type": "client_credentials",
              "client_id": client_id,
              "client_secret": client_secret},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def _get(token: str, url: str, **params) -> dict:
    r = requests.get(url, headers={"Authorization": f"Bearer {token}"},
                     params=params, timeout=15)
    if r.status_code == 429:
        retry = int(r.headers.get("Retry-After", "2"))
        console.print(f"[yellow]Rate limited — waiting {retry}s…[/]")
        time.sleep(retry)
        return _get(token, url, **params)
    r.raise_for_status()
    return r.json()

# ── Search ─────────────────────────────────────────────────────────────────────

def search_artists(token: str, query: str, limit: int = 8) -> list[dict]:
    data = _get(token, "https://api.spotify.com/v1/search",
                q=query, type="artist", market="DE", limit=limit)
    return data.get("artists", {}).get("items", [])


def pick_artist(token: str, query: str, auto_pick: int | None) -> dict | None:
    artists = search_artists(token, query)
    if not artists:
        console.print("[red]No artists found.[/]")
        return None

    t = Table(title=f'Artists matching "{query}"', box=box.SIMPLE_HEAD)
    t.add_column("#",         width=3, justify="right")
    t.add_column("Name",      min_width=30)
    t.add_column("Followers", width=12, justify="right")
    t.add_column("ID",        width=24)
    t.add_column("Genres",    min_width=20)

    for i, a in enumerate(artists):
        t.add_row(
            str(i),
            f"[bold]{a['name']}[/]" if a["name"].lower() == query.lower() else a["name"],
            f"{a['followers']['total']:,}",
            a["id"],
            ", ".join(a.get("genres", [])[:3]) or "–",
        )
    console.print(t)

    if auto_pick is not None:
        chosen = artists[auto_pick]
        console.print(f"[dim]Auto-picked #{auto_pick}: {chosen['name']}[/]")
        return chosen

    console.print("Enter # to select (or press Enter to quit): ", end="")
    raw = input().strip()
    if not raw:
        return None
    try:
        return artists[int(raw)]
    except (ValueError, IndexError):
        console.print("[red]Invalid choice.[/]")
        return None

# ── Discography ────────────────────────────────────────────────────────────────

def fetch_albums(token: str, artist_id: str, use_cache: bool = True) -> list[dict]:
    cache_path = CACHE_DIR / f"{artist_id}.json"
    if use_cache and cache_path.exists():
        console.print(f"[dim]Using cached discography for {artist_id}[/]")
        return json.loads(cache_path.read_text())

    console.print(f"Fetching discography for [bold]{artist_id}[/]…")
    albums: list[dict] = []
    url = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
    params: dict = {"market": "DE", "limit": 50, "album_type": "album,single,compilation"}

    while url:
        data   = _get(token, url, **params)
        albums.extend(data.get("items", []))
        url    = data.get("next", "")       # type: ignore[assignment]
        params = {}                          # next URL already has params
        time.sleep(0.1)

    cache_path.write_text(json.dumps(albums, ensure_ascii=False, indent=2))
    console.print(f"  → {len(albums)} albums (cached)")
    return albums

# ── Pattern analysis ───────────────────────────────────────────────────────────

# Known episode-number prefixes in DACH Hörspiele, in priority order.
_PATTERNS: list[tuple[str, str]] = [
    ("NNN/",      r"^(\d{1,3})/"),
    ("N:",        r"^(\d{1,2}):\s"),
    ("Folge N",   r"[Ff]olge\s+(\d+)"),
    ("Teil N",    r"[Tt]eil\s+(\d+)"),
    ("Episode N", r"[Ee]pisode\s+(\d+)"),
    ("Fall N",    r"[Ff]all\s+(\d+)"),
    ("Band N",    r"[Bb]and\s+(\d+)"),
    ("Hörspiel N",r"[Hh]örspiel\s+(\d+)"),
    ("Nr. N",     r"[Nn]r\.?\s+(\d+)"),
]

def _extract_num(title: str) -> int | None:
    """Return the first episode number found in a title, or None."""
    for _, pat in _PATTERNS:
        m = re.search(pat, title)
        if m:
            return int(m.group(1))
    return None

def _which_pattern(title: str) -> str | None:
    for name, pat in _PATTERNS:
        if re.search(pat, title):
            return name
    return None


def analyse_patterns(albums: list[dict]) -> dict:
    titles = [a["name"] for a in albums]

    # Per-pattern hit counts
    hits: Counter[str] = Counter()
    for _, pat in _PATTERNS:
        for t in titles:
            if re.search(pat, t):
                hits[_which_pattern(t) or "?"] += 1  # count by name not pat

    # Re-count properly: for each title, which (first-matching) pattern fires?
    pattern_of: dict[str, str] = {}  # title → pattern name
    for t in titles:
        pn = _which_pattern(t)
        if pn:
            pattern_of[t] = pn

    by_pattern: Counter[str] = Counter(pattern_of.values())
    unmatched = [t for t in titles if t not in pattern_of]

    # Sort all titles by extracted episode number for gap detection
    numbered = sorted(
        [(t, _extract_num(t)) for t in titles if _extract_num(t) is not None],
        key=lambda x: x[1],  # type: ignore[index]
    )

    # Find gaps in the sequence
    nums = [n for _, n in numbered]
    full_range = set(range(min(nums), max(nums) + 1)) if nums else set()
    gaps = sorted(full_range - set(nums))

    return {
        "total":       len(titles),
        "by_pattern":  dict(by_pattern.most_common()),
        "unmatched":   unmatched,
        "numbered":    numbered,   # (title, episode_num) sorted
        "gaps":        gaps,
    }


def print_analysis(artist: dict, albums: list[dict], analysis: dict) -> None:
    console.print(Panel(
        f"[bold]{artist['name']}[/]  [dim]{artist['id']}[/]\n"
        f"Followers: {artist['followers']['total']:,} · Albums: {analysis['total']}",
        title="📊 Discography analysis",
    ))

    t = Table(box=box.SIMPLE, title="Episode patterns (first-match wins)")
    t.add_column("Pattern",  min_width=12)
    t.add_column("Matches",  justify="right", width=8)
    t.add_column("Coverage", justify="right", width=8)
    total = analysis["total"]
    for name, count in analysis["by_pattern"].items():
        t.add_row(name, str(count), f"{round(100*count/total)}%")
    if analysis["unmatched"]:
        t.add_row("[dim]unmatched[/]", str(len(analysis["unmatched"])),
                  f"{round(100*len(analysis['unmatched'])/total)}%",
                  style="dim")
    console.print(t)

    if analysis["gaps"]:
        console.print(f"[yellow]Sequence gaps:[/] {analysis['gaps'][:20]}")

    if analysis["unmatched"]:
        console.print("\n[yellow]Unmatched titles:[/]")
        for u in analysis["unmatched"][:10]:
            console.print(f"  [dim]{u}[/]")

    console.print("\n[bold]All titles sorted by episode number:[/]")
    for title, num in analysis["numbered"][:20]:
        console.print(f"  {num:>4}  {title}")

# ── AI-assisted YAML generation ────────────────────────────────────────────────

_YAML_PROMPT = """\
You are helping maintain the lauschi DACH kids audio player catalog (series.yaml).
Produce a single YAML entry for the series below. Use ONLY information given here —
do NOT hallucinate artist IDs or album counts.

Rules:
- id: snake_case, lowercase, ASCII only
- title: canonical German title
- aliases: alternative titles Spotify may use (list, omit if empty)
- keywords: lowercase words or phrases from the SERIES NAME that also appear
  in album titles. Look at the samples — if the series name does NOT appear in
  album titles at all (e.g. titles are just "Teil 5: …"), omit keywords
  entirely (the spotify_artist_ids will handle matching instead).
  Never use generic German words like "einhorn", "zauberer" etc. as keywords.
- spotify_artist_ids: use the provided artist ID (as a list)
- episode_pattern: a Python regex with ONE capture group for the episode number.
  Use the dominant pattern from the analysis (e.g. "[Tt]eil\\s+(\\d+)").
  Use \\d+ not \\d{{1,3}} unless you have a specific reason.
  Omit if no consistent numbering (standalone stories).
- Add a short # comment on the same line as the artist ID: (Xk followers, N albums, dominant format)
- Do NOT include discover_query.
- Output ONLY the YAML block, no markdown fences, no explanations.

Series info
-----------
{info}

Sample album titles (first 40)
-------------------------------
{titles}

Pattern analysis
----------------
{patterns}
"""

def run_ai(artist: dict, albums: list[dict], analysis: dict,
           model: str) -> str | None:
    info = (
        f"Artist name   : {artist['name']}\n"
        f"Artist ID     : {artist['id']}\n"
        f"Spotify followers: {artist['followers']['total']:,}\n"
        f"Total albums  : {analysis['total']}"
    )
    titles_block = "\n".join(f"  - {a['name']}" for a in albums[:40])
    patterns_block = "\n".join(
        f"  {name}: {count} hits ({pct}%)"
        for name, (count, pct) in analysis["hits"].items()
    ) or "  (no consistent numbering detected)"

    prompt = _YAML_PROMPT.format(
        info=info, titles=titles_block, patterns=patterns_block
    )

    console.print(f"\n[dim]Calling pi ({model}) for YAML generation…[/]")
    try:
        result = subprocess.run(
            ["pi", "-p", "--model", model, "--no-session", prompt],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode != 0:
            console.print(f"[red]pi exited {result.returncode}:[/] {result.stderr[:200]}")
            return None
        out = result.stdout
        # Strip ANSI/OSC escape sequences
        out = re.sub(r"\x1b(?:\[[0-9;]*[mABCDEFGHJKSTfhilmnprsu]|\][^\x1b\x07]*(?:\x07|\x1b\\))", "", out)
        # Strip OSC notify sequences (]NNN;...  format pi emits)
        out = re.sub(r"\]\d+;[^\n]*", "", out)
        # Strip markdown fences if the model wrapped in ```yaml ... ```
        out = re.sub(r"^```[a-z]*\n?", "", out.strip(), flags=re.MULTILINE)
        out = re.sub(r"\n?```$", "", out.strip(), flags=re.MULTILINE)
        return out.strip()
    except subprocess.TimeoutExpired:
        console.print("[red]pi timed out.[/]")
        return None
    except FileNotFoundError:
        console.print("[red]`pi` not found in PATH.[/]")
        return None

# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Discover Spotify series for the lauschi catalog.",
        epilog='Example: uv run scripts/discover-titles.py "Sternenschweif" --ai',
    )
    ap.add_argument("query",        nargs="?", help="Artist/series name to search for")
    ap.add_argument("--artist-id",  help="Use this Spotify artist ID directly (skip search)")
    ap.add_argument("--pick",       type=int, metavar="N",
                    help="Auto-pick search result #N (0-indexed, skips interactive prompt)")
    ap.add_argument("--ai",         action="store_true",
                    help="Call `pi` to generate a series.yaml snippet")
    ap.add_argument("--model",      default="claude-sonnet-4-5",
                    help="pi model for --ai (default: claude-sonnet-4-5)")
    ap.add_argument("--no-cache",   action="store_true",
                    help="Bypass local discography cache")
    args = ap.parse_args()

    if not args.query and not args.artist_id:
        ap.print_help()
        sys.exit(1)

    token = _token()

    # ── Resolve artist ────────────────────────────────────────────────────────
    if args.artist_id:
        artist_data = _get(token, f"https://api.spotify.com/v1/artists/{args.artist_id}")
    else:
        artist_data = pick_artist(token, args.query, args.pick)  # type: ignore[arg-type]
        if not artist_data:
            sys.exit(0)

    # ── Fetch & analyse discography ───────────────────────────────────────────
    albums   = fetch_albums(token, artist_data["id"], use_cache=not args.no_cache)
    analysis = analyse_patterns(albums)
    print_analysis(artist_data, albums, analysis)

    # ── AI YAML generation ────────────────────────────────────────────────────
    if args.ai:
        yaml_block = run_ai(artist_data, albums, analysis, args.model)
        if yaml_block:
            console.print(Panel(yaml_block, title="✅ Suggested series.yaml entry",
                                border_style="green"))
        else:
            console.print("[yellow]AI generation failed — use the analysis above manually.[/]")


if __name__ == "__main__":
    main()
