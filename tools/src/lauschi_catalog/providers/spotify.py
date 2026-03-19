"""Spotify provider with disk caching."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import diskcache
import requests

from lauschi_catalog.providers.base import Album, Artist, CatalogProvider, Track

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CACHE_DIR = REPO_ROOT / ".cache" / "spotify"
DEFAULT_TTL = 7 * 24 * 3600  # 7 days


class SpotifyProvider(CatalogProvider):
    """Spotify Web API with transparent disk caching and auto token refresh."""

    def __init__(self, *, use_cache: bool = True) -> None:
        self._cache = diskcache.Cache(str(CACHE_DIR), size_limit=500 * 1024 * 1024)
        self._use_cache = use_cache

        self._cid = os.environ.get("SPOTIFY_CLIENT_ID", "")
        self._csec = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
        if not self._cid or not self._csec:
            print(
                "SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET not set.",
                file=sys.stderr,
            )
            sys.exit(1)

        self._token = self._fetch_token()
        self._token_time = time.time()

    def _fetch_token(self) -> str:
        """Get a fresh client credentials token."""
        r = requests.post(
            "https://accounts.spotify.com/api/token",
            data={
                "grant_type": "client_credentials",
                "client_id": self._cid,
                "client_secret": self._csec,
            },
            timeout=10,
        )
        r.raise_for_status()
        return r.json()["access_token"]

    def _ensure_token(self) -> None:
        """Refresh the token if it's older than 55 minutes (expires at 60)."""
        if time.time() - self._token_time > 3300:
            self._token = self._fetch_token()
            self._token_time = time.time()

    @property
    def name(self) -> str:
        return "spotify"

    def _get(self, url: str, **params) -> dict:
        self._ensure_token()
        full_url = url if url.startswith("http") else f"https://api.spotify.com/v1/{url}"
        for attempt in range(3):
            r = requests.get(
                full_url,
                headers={"Authorization": f"Bearer {self._token}"},
                params=params,
                timeout=20,
            )
            if r.status_code == 429:
                time.sleep(int(r.headers.get("Retry-After", "2")))
                continue
            if r.status_code == 401:
                # Token expired mid-request. Refresh and retry.
                self._token = self._fetch_token()
                self._token_time = time.time()
                continue
            r.raise_for_status()
            return r.json()
        # Exhausted retries
        r.raise_for_status()
        return {}  # unreachable, raise_for_status throws

    def _cached(self, key: str, fetch):
        if self._use_cache:
            cached = self._cache.get(key)
            if cached is not None:
                return cached
        result = fetch()
        self._cache.set(key, result, expire=DEFAULT_TTL)
        return result

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        def fetch():
            data = self._get("search", q=query, type="artist", market="DE", limit=limit)
            return data.get("artists", {}).get("items", [])

        raw = self._cached(f"search_artists:{query.lower()}:{limit}", fetch)
        return [
            Artist(
                id=a["id"],
                name=a["name"],
                provider="spotify",
                genres=a.get("genres", []),
                followers=a.get("followers", {}).get("total", 0)
                if isinstance(a.get("followers"), dict)
                else a.get("followers", 0),
            )
            for a in raw
        ]

    def artist_albums(self, artist_id: str) -> list[Album]:
        def fetch():
            raw: list[dict] = []
            url = f"https://api.spotify.com/v1/artists/{artist_id}/albums"
            p: dict = {"market": "DE", "limit": 50, "album_type": "album,single,compilation"}
            while url:
                data = self._get(url, **p)
                raw.extend(data.get("items", []))
                url = data.get("next") or ""
                p = {}
                time.sleep(0.05)
            return raw

        raw = self._cached(f"artist_albums:{artist_id}", fetch)
        return [
            Album(
                id=a["id"],
                name=a["name"],
                provider="spotify",
                release_date=a.get("release_date", ""),
                total_tracks=a.get("total_tracks", 0),
            )
            for a in raw
        ]

    def album_details(self, album_id: str) -> Album | None:
        def fetch():
            time.sleep(0.05)
            try:
                return self._get(f"albums/{album_id}", market="DE")
            except requests.HTTPError:
                return None

        data = self._cached(f"album:{album_id}", fetch)
        if data is None or "error" in data:
            return None

        return Album(
            id=data["id"],
            name=data["name"],
            provider="spotify",
            release_date=data.get("release_date", ""),
            total_tracks=data.get("total_tracks", 0),
            label=data.get("label", ""),
            tracks=[
                Track(name=t["name"], duration_ms=t.get("duration_ms", 0))
                for t in data.get("tracks", {}).get("items", [])
            ],
        )

    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        def fetch():
            data = self._get("search", q=query, type="album", market="DE", limit=limit)
            return data.get("albums", {}).get("items", [])

        raw = self._cached(f"search_albums:{query.lower()}:{limit}", fetch)
        return [
            Album(
                id=a["id"],
                name=a["name"],
                provider="spotify",
                total_tracks=a.get("total_tracks", 0),
                artists=", ".join(art["name"] for art in a.get("artists", [])),
            )
            for a in raw
        ]

    def clear_cache(self) -> int:
        count = len(self._cache)
        self._cache.clear()
        return count
