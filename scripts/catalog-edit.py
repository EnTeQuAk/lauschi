#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.0", "requests"]
# ///
"""
catalog-edit.py — CLI for editing curation JSONs.

Headless companion to review-curation.py TUI. Suitable for scripted or
AI-assisted review workflows.

Usage
-----
  # Add a missing album (fetches from Spotify, extracts episode number)
  mise exec -- uv run scripts/catalog-edit.py add fuenf_freunde ALBUM_ID

  # Remove an album
  mise exec -- uv run scripts/catalog-edit.py remove fuenf_freunde ALBUM_ID

  # Toggle include/exclude
  mise exec -- uv run scripts/catalog-edit.py toggle fuenf_freunde ALBUM_ID

  # Set episode number
  mise exec -- uv run scripts/catalog-edit.py set-episode fuenf_freunde ALBUM_ID 42

  # Approve a series (writes to series.yaml)
  mise exec -- uv run scripts/catalog-edit.py approve fuenf_freunde

  # Show series summary
  mise exec -- uv run scripts/catalog-edit.py show fuenf_freunde

  # Search Spotify for an album by name (to find IDs for gap-filling)
  mise exec -- uv run scripts/catalog-edit.py search "Fünf Freunde 008"
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import UTC, datetime
from pathlib import Path

import requests

REPO_ROOT = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
SERIES_YAML = REPO_ROOT / "assets" / "catalog" / "series.yaml"


def _spotify_token() -> str:
    cid = os.environ.get("SPOTIFY_CLIENT_ID", "")
    csec = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
    if not cid or not csec:
        print("ERROR: SPOTIFY_CLIENT_ID/SECRET not set", file=sys.stderr)
        sys.exit(1)
    r = requests.post(
        "https://accounts.spotify.com/api/token",
        data={"grant_type": "client_credentials",
              "client_id": cid, "client_secret": csec},
        timeout=10,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def _spotify_get(token: str, url: str, **params: str | int) -> dict:
    r = requests.get(
        url if url.startswith("http") else f"https://api.spotify.com/v1/{url}",
        headers={"Authorization": f"Bearer {token}"},
        params=params,
        timeout=10,
    )
    r.raise_for_status()
    return r.json()


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


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_show(series_id: str) -> None:
    data = load_curation(series_id)
    series = data["series"]
    albums = series.get("albums", [])
    included = [a for a in albums if a.get("include")]
    excluded = [a for a in albums if not a.get("include")]
    eps = sorted(a["episode_num"] for a in included if a.get("episode_num") is not None)
    status = data.get("review", {}).get("status", "pending")

    print(f"Series: {series['title']} ({series['id']})")
    print(f"Status: {status}")
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

    token = _spotify_token()
    info = _spotify_get(token, f"albums/{album_id}", market="DE")
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


def cmd_remove(series_id: str, album_id: str) -> None:
    data = load_curation(series_id)
    series = data["series"]
    before = len(series.get("albums", []))
    series["albums"] = [a for a in series.get("albums", []) if a["spotify_album_id"] != album_id]
    after = len(series["albums"])
    if before == after:
        print(f"Not found: {album_id}")
        return
    save_curation(series_id, data)
    print(f"Removed {album_id}")


def cmd_toggle(series_id: str, album_id: str) -> None:
    data = load_curation(series_id)
    for a in data["series"].get("albums", []):
        if a["spotify_album_id"] == album_id:
            a["include"] = not a["include"]
            if not a["include"] and not a.get("exclude_reason"):
                a["exclude_reason"] = "Reviewer override"
            save_curation(series_id, data)
            state = "included" if a["include"] else "excluded"
            print(f"Toggled {a['title']} → {state}")
            return
    print(f"Not found: {album_id}")


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
    token = _spotify_token()
    data = _spotify_get(token, "search", q=query, type="album", market="DE", limit=10)
    for item in data.get("albums", {}).get("items", []):
        artists = ", ".join(a["name"] for a in item.get("artists", []))
        print(f"  {item['id']}  {item['name']}  ({item.get('total_tracks', '?')} tracks)  by {artists}")


def cmd_search_artist_albums(artist_id: str, query: str = "") -> None:
    """List all albums for an artist, optionally filtered."""
    token = _spotify_token()
    albums = []
    url = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
    params: dict = {"market": "DE", "limit": 50, "album_type": "album,single,compilation"}
    while url:
        data = _spotify_get(token, url, **params)
        albums.extend(data.get("items", []))
        url = data.get("next", "")
        params = {}

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

    p = sub.add_parser("remove", help="Remove album")
    p.add_argument("series_id")
    p.add_argument("album_id")

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
    elif args.command == "remove":
        cmd_remove(args.series_id, args.album_id)
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
