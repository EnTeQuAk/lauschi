"""Shared Spotify API client with disk caching.

All scripts import from here instead of maintaining separate clients.
Cache lives in .cache/spotify/ with configurable TTL (default 7 days).
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Any

import diskcache
import requests

REPO_ROOT = Path(__file__).parent.parent
CACHE_DIR = REPO_ROOT / ".cache" / "spotify"

_cache = diskcache.Cache(str(CACHE_DIR), size_limit=500 * 1024 * 1024)  # 500 MB

# 7 days — album data doesn't change often
DEFAULT_TTL = 7 * 24 * 3600


class SpotifyClient:
    """Spotify Web API client with transparent disk caching."""

    def __init__(self) -> None:
        cid = os.environ.get("SPOTIFY_CLIENT_ID", "")
        csec = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
        if not cid or not csec:
            print("SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET not set.", file=sys.stderr)
            sys.exit(1)
        r = requests.post(
            "https://accounts.spotify.com/api/token",
            data={
                "grant_type": "client_credentials",
                "client_id": cid,
                "client_secret": csec,
            },
            timeout=10,
        )
        r.raise_for_status()
        self._token = r.json()["access_token"]

    def _get(self, url: str, **params: Any) -> dict:
        while True:
            r = requests.get(
                url if url.startswith("http") else f"https://api.spotify.com/v1/{url}",
                headers={"Authorization": f"Bearer {self._token}"},
                params=params,
                timeout=20,
            )
            if r.status_code == 429:
                time.sleep(int(r.headers.get("Retry-After", "2")))
                continue
            r.raise_for_status()
            return r.json()

    def search_artists(self, query: str, limit: int = 8) -> list[dict]:
        key = f"search_artists:{query.lower()}:{limit}"
        cached = _cache.get(key)
        if cached is not None:
            return cached
        data = self._get("search", q=query, type="artist", market="DE", limit=limit)
        result = [
            {
                "id": a["id"],
                "name": a["name"],
                "followers": a["followers"]["total"],
                "genres": a.get("genres", []),
            }
            for a in data.get("artists", {}).get("items", [])
        ]
        _cache.set(key, result, expire=DEFAULT_TTL)
        return result

    def search_albums(self, query: str, limit: int = 10) -> list[dict]:
        key = f"search_albums:{query.lower()}:{limit}"
        cached = _cache.get(key)
        if cached is not None:
            return cached
        data = self._get("search", q=query, type="album", market="DE", limit=limit)
        result = [
            {
                "id": a["id"],
                "name": a["name"],
                "total_tracks": a.get("total_tracks", 0),
                "artists": ", ".join(art["name"] for art in a.get("artists", [])),
            }
            for a in data.get("albums", {}).get("items", [])
        ]
        _cache.set(key, result, expire=DEFAULT_TTL)
        return result

    def artist_albums(self, artist_id: str) -> list[dict]:
        key = f"artist_albums:{artist_id}"
        cached = _cache.get(key)
        if cached is not None:
            return cached
        raw: list[dict] = []
        url = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
        p: dict = {"market": "DE", "limit": 50, "album_type": "album,single,compilation"}
        while url:
            data = self._get(url, **p)
            raw.extend(data.get("items", []))
            url = data.get("next") or ""
            p = {}
            time.sleep(0.05)
        result = [
            {
                "id": a["id"],
                "name": a["name"],
                "release_date": a.get("release_date", ""),
                "total_tracks": a.get("total_tracks", 0),
            }
            for a in raw
        ]
        _cache.set(key, result, expire=DEFAULT_TTL)
        return result

    def album_details(self, album_id: str) -> dict:
        """Full album details including tracks. Returns error dict on 404."""
        key = f"album:{album_id}"
        cached = _cache.get(key)
        if cached is not None:
            return cached
        time.sleep(0.05)
        try:
            data = self._get(f"albums/{album_id}", market="DE")
        except requests.HTTPError:
            error = {"error": f"Album {album_id} not found"}
            _cache.set(key, error, expire=DEFAULT_TTL)
            return error
        result = {
            "id": data["id"],
            "name": data["name"],
            "release_date": data.get("release_date", ""),
            "total_tracks": data.get("total_tracks", 0),
            "label": data.get("label", ""),
            "tracks": [
                {"name": t["name"], "duration_ms": t.get("duration_ms", 0)}
                for t in data.get("tracks", {}).get("items", [])
            ],
        }
        _cache.set(key, result, expire=DEFAULT_TTL)
        return result


def clear_cache() -> int:
    """Clear all cached data. Returns number of entries removed."""
    count = len(_cache)
    _cache.clear()
    return count
