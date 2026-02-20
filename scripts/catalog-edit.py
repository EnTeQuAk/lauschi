#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.0", "requests", "diskcache"]
# ///
"""
catalog-edit.py — CLI for editing curation JSONs.

Headless companion to review-curation.py TUI. Suitable for scripted or
AI-assisted review workflows. All edits are non-destructive — they write
to review.overrides, preserving the original AI curation.

Usage
-----
  # Add a missing album (fetches from Spotify, extracts episode number)
  mise exec -- uv run scripts/catalog-edit.py add fuenf_freunde ALBUM_ID

  # Exclude an album (non-destructive override with reason)
  mise exec -- uv run scripts/catalog-edit.py exclude fuenf_freunde ALBUM_ID "Sub-series: JUNIOR"

  # Toggle include/exclude (non-destructive override)
  mise exec -- uv run scripts/catalog-edit.py toggle fuenf_freunde ALBUM_ID

  # Set episode number
  mise exec -- uv run scripts/catalog-edit.py set-episode fuenf_freunde ALBUM_ID 42

  # Approve a series
  mise exec -- uv run scripts/catalog-edit.py approve fuenf_freunde

  # Show series summary (with overrides applied)
  mise exec -- uv run scripts/catalog-edit.py show fuenf_freunde

  # Search Spotify for an album by name (to find IDs for gap-filling)
  mise exec -- uv run scripts/catalog-edit.py search "Fünf Freunde 008"
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
SERIES_YAML = REPO_ROOT / "assets" / "catalog" / "series.yaml"

# Shared cached Spotify client (see spotify_cache.py)
sys.path.insert(0, str(Path(__file__).parent))
from spotify_cache import SpotifyClient  # noqa: E402

# Lazily initialized — only commands that need Spotify create it
_spotify: SpotifyClient | None = None

def _get_spotify() -> SpotifyClient:
    global _spotify  # noqa: PLW0603
    if _spotify is None:
        _spotify = SpotifyClient()
    return _spotify


def load_curation(series_id: str) -> dict:
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr)
        sys.exit(1)
    return json.loads(path.read_text())


def save_curation(series_id: str, data: dict) -> None:
    path = CURATION_DIR / f"{series_id}.json"
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def extract_episode(pattern: str | None, title: str) -> int | None:
    if not pattern:
        return None
    m = re.search(pattern, title)
    if m and m.groups():
        try:
            return int(m.group(1))
        except (ValueError, IndexError):
            pass
    return None


# ── Helpers ───────────────────────────────────────────────────────────────────

def _effective_albums(data: dict) -> list[dict]:
    """Apply review overrides on top of the AI decisions."""
    albums = data.get("series", {}).get("albums", [])
    overrides = {o["album_id"]: o
                 for o in data.get("review", {}).get("overrides", [])}
    result = []
    for a in albums:
        a = dict(a)  # copy
        aid = a["spotify_album_id"]
        if aid in overrides:
            ov = overrides[aid]
            a["include"] = ov["action"] == "include"
            if not a["include"]:
                a["exclude_reason"] = ov.get("reason", "Reviewer override")
        result.append(a)
    return result


def _set_override(data: dict, album_id: str, action: str, reason: str = "") -> None:
    """Add or update a review override."""
    review = data.setdefault("review", {})
    overrides = review.setdefault("overrides", [])
    for ov in overrides:
        if ov["album_id"] == album_id:
            ov["action"] = action
            if reason:
                ov["reason"] = reason
            return
    overrides.append({"album_id": album_id, "action": action, "reason": reason})


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_show(series_id: str) -> None:
    data = load_curation(series_id)
    series = data["series"]
    albums = _effective_albums(data)
    included = [a for a in albums if a.get("include")]
    excluded = [a for a in albums if not a.get("include")]
    eps = sorted(a["episode_num"] for a in included if a.get("episode_num") is not None)
    status = data.get("review", {}).get("status", "pending")
    num_overrides = len(data.get("review", {}).get("overrides", []))

    print(f"Series: {series['title']} ({series['id']})")
    print(f"Status: {status}")
    if num_overrides:
        print(f"Overrides: {num_overrides}")
    print(f"Artists: {', '.join(series.get('spotify_artist_ids', []))}")
    print(f"Pattern: {series.get('episode_pattern', '—')}")
    print(f"Included: {len(included)}, Excluded: {len(excluded)}")
    if eps:
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        print(f"Episode range: {min(eps)}–{max(eps)}")
        if gaps:
            print(f"Gaps: {gaps}")

    # Show duplicates
    from collections import Counter
    counts = Counter(a["episode_num"] for a in included if a.get("episode_num") is not None)
    dupes = sorted(ep for ep, n in counts.items() if n > 1)
    if dupes:
        print(f"Duplicate episodes: {dupes}")
        for ep in dupes:
            entries = [a for a in included if a.get("episode_num") == ep]
            for e in entries:
                print(f"  ep {ep}: {e['title']}  [{e['spotify_album_id']}]")


def cmd_add(series_id: str, album_id: str) -> None:
    data = load_curation(series_id)
    series = data["series"]

    # Check duplicate
    existing = {a["spotify_album_id"] for a in series.get("albums", [])}
    if album_id in existing:
        print(f"Already exists: {album_id}")
        return

    info = _get_spotify().album_details(album_id)
    if "error" in info:
        print(f"ERROR: {info['error']}", file=sys.stderr)
        return
    title = info["name"]
    episode_num = extract_episode(series.get("episode_pattern"), title)

    series.setdefault("albums", []).append({
        "spotify_album_id": album_id,
        "include": True,
        "episode_num": episode_num,
        "title": title,
        "exclude_reason": None,
    })
    save_curation(series_id, data)
    ep_str = f" (episode {episode_num})" if episode_num else ""
    print(f"Added: {title}{ep_str}  [{album_id}]")


def cmd_exclude(series_id: str, album_id: str, reason: str = "") -> None:
    data = load_curation(series_id)
    # Verify album exists
    albums = {a["spotify_album_id"]: a for a in data["series"].get("albums", [])}
    if album_id not in albums:
        print(f"Not found: {album_id}")
        return
    _set_override(data, album_id, "exclude", reason or "Reviewer override")
    save_curation(series_id, data)
    print(f"Excluded: {albums[album_id]['title']}  [{album_id}]")
    if reason:
        print(f"  Reason: {reason}")


def cmd_toggle(series_id: str, album_id: str) -> None:
    data = load_curation(series_id)
    albums = {a["spotify_album_id"]: a for a in data["series"].get("albums", [])}
    if album_id not in albums:
        print(f"Not found: {album_id}")
        return
    # Check effective state to determine toggle direction
    effective = {a["spotify_album_id"]: a for a in _effective_albums(data)}
    currently_included = effective[album_id].get("include", False)
    new_action = "exclude" if currently_included else "include"
    _set_override(data, album_id, new_action,
                  "Reviewer override" if new_action == "exclude" else "")
    save_curation(series_id, data)
    state = "excluded" if new_action == "exclude" else "included"
    print(f"Toggled {albums[album_id]['title']} → {state}")


def cmd_set_episode(series_id: str, album_id: str, episode_num: int) -> None:
    data = load_curation(series_id)
    for a in data["series"].get("albums", []):
        if a["spotify_album_id"] == album_id:
            a["episode_num"] = episode_num
            save_curation(series_id, data)
            print(f"Set {a['title']} → episode {episode_num}")
            return
    print(f"Not found: {album_id}")


def cmd_approve(series_id: str) -> None:
    data = load_curation(series_id)
    data.setdefault("review", {})["status"] = "approved"
    data["review"]["reviewed_at"] = datetime.now(tz=UTC).isoformat()
    save_curation(series_id, data)
    # Don't write YAML — let the human do that via TUI
    print(f"Approved: {data['series']['title']}")


def cmd_search(query: str) -> None:
    results = _get_spotify().search_albums(query)
    for item in results:
        print(f"  {item['id']}  {item['name']}  ({item.get('total_tracks', '?')} tracks)  {item.get('artists', '')}")


def cmd_search_artist_albums(artist_id: str, query: str = "") -> None:
    """List all albums for an artist, optionally filtered."""
    albums = _get_spotify().artist_albums(artist_id)
    for a in albums:
        name = a["name"]
        if query and query.lower() not in name.lower():
            continue
        print(f"  {a['id']}  {name}  ({a.get('total_tracks', '?')} tracks)  {a.get('release_date', '')}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="CLI for editing curation JSONs.")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("show", help="Show series summary")
    p.add_argument("series_id")

    p = sub.add_parser("add", help="Add album by Spotify ID")
    p.add_argument("series_id")
    p.add_argument("album_id")

    p = sub.add_parser("exclude", help="Exclude album (non-destructive override)")
    p.add_argument("series_id")
    p.add_argument("album_id")
    p.add_argument("reason", nargs="?", default="", help="Reason for exclusion")

    p = sub.add_parser("toggle", help="Toggle include/exclude")
    p.add_argument("series_id")
    p.add_argument("album_id")

    p = sub.add_parser("set-episode", help="Set episode number")
    p.add_argument("series_id")
    p.add_argument("album_id")
    p.add_argument("episode_num", type=int)

    p = sub.add_parser("approve", help="Mark series as approved")
    p.add_argument("series_id")

    p = sub.add_parser("search", help="Search Spotify for albums")
    p.add_argument("query")

    p = sub.add_parser("artist-albums", help="List albums for an artist ID")
    p.add_argument("artist_id")
    p.add_argument("query", nargs="?", default="", help="Filter by name")

    args = ap.parse_args()

    if args.command == "show":
        cmd_show(args.series_id)
    elif args.command == "add":
        cmd_add(args.series_id, args.album_id)
    elif args.command == "exclude":
        cmd_exclude(args.series_id, args.album_id, args.reason)
    elif args.command == "toggle":
        cmd_toggle(args.series_id, args.album_id)
    elif args.command == "set-episode":
        cmd_set_episode(args.series_id, args.album_id, args.episode_num)
    elif args.command == "approve":
        cmd_approve(args.series_id)
    elif args.command == "search":
        cmd_search(args.query)
    elif args.command == "artist-albums":
        cmd_search_artist_albums(args.artist_id, args.query)


if __name__ == "__main__":
    main()
