"""Apple Music provider with disk caching."""

from __future__ import annotations

import time
from pathlib import Path

import diskcache
import jwt
import requests

from lauschi_catalog.providers.base import Album, Artist, CatalogProvider, Track

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CACHE_DIR = REPO_ROOT / ".cache" / "apple_music"
KEY_PATH = REPO_ROOT / "android" / "app" / "AuthKey_PWHK2R76T9.p8"
DEFAULT_TTL = 7 * 24 * 3600  # 7 days

# MusicKit config
TEAM_ID = "QDF8U52UF4"
KEY_ID = "PWHK2R76T9"
STOREFRONT = "de"


class AppleMusicProvider(CatalogProvider):
    """Apple Music API with transparent disk caching and auto token refresh."""

    def __init__(self, *, use_cache: bool = True) -> None:
        self._cache = diskcache.Cache(str(CACHE_DIR), size_limit=500 * 1024 * 1024)
        self._use_cache = use_cache
        self._token = self._generate_token()
        self._token_time = time.time()

    @property
    def name(self) -> str:
        return "apple_music"

    @staticmethod
    def _generate_token() -> str:
        if not KEY_PATH.exists():
            msg = f"MusicKit key not found at {KEY_PATH}"
            raise FileNotFoundError(msg)
        key = KEY_PATH.read_text()
        now = int(time.time())
        return jwt.encode(
            {"iss": TEAM_ID, "iat": now, "exp": now + 3600},
            key,
            algorithm="ES256",
            headers={"kid": KEY_ID},
        )

    def _ensure_token(self) -> None:
        """Refresh token if older than 55 minutes (expires at 60)."""
        if time.time() - self._token_time > 3300:
            self._token = self._generate_token()
            self._token_time = time.time()

    def _get(self, path: str, **params) -> dict:
        self._ensure_token()
        url = f"https://api.music.apple.com/v1/catalog/{STOREFRONT}/{path}"
        for attempt in range(3):
            r = requests.get(
                url,
                headers={"Authorization": f"Bearer {self._token}"},
                params=params,
                timeout=15,
            )
            if r.status_code == 401:
                self._token = self._generate_token()
                self._token_time = time.time()
                continue
            r.raise_for_status()
            return r.json()
        r.raise_for_status()
        return {}

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
            data = self._get("search", term=query, types="artists", limit=limit)
            return data.get("results", {}).get("artists", {}).get("data", [])

        raw = self._cached(f"am_search_artists:{query.lower()}:{limit}", fetch)
        time.sleep(0.1)
        return [
            Artist(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                genres=a["attributes"].get("genreNames", []),
            )
            for a in raw
        ]

    def artist_albums(self, artist_id: str) -> list[Album]:
        def fetch():
            # Apple Music paginates at 25 by default, max 100.
            all_albums: list[dict] = []
            url = f"artists/{artist_id}/albums"
            params = {"limit": 100}
            data = self._get(url, **params)
            all_albums.extend(data.get("data", []))
            # Follow pagination
            next_url = data.get("next")
            while next_url:
                time.sleep(0.1)
                r = requests.get(
                    f"https://api.music.apple.com{next_url}",
                    headers={"Authorization": f"Bearer {self._token}"},
                    timeout=15,
                )
                r.raise_for_status()
                page = r.json()
                all_albums.extend(page.get("data", []))
                next_url = page.get("next")
            return all_albums

        raw = self._cached(f"am_artist_albums:{artist_id}", fetch)
        time.sleep(0.1)
        return [
            Album(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                release_date=a["attributes"].get("releaseDate", ""),
                total_tracks=a["attributes"].get("trackCount", 0),
                artists=a["attributes"].get("artistName", ""),
            )
            for a in raw
        ]

    def album_details(self, album_id: str) -> Album | None:
        def fetch():
            time.sleep(0.1)
            try:
                data = self._get(f"albums/{album_id}", include="tracks")
                items = data.get("data", [])
                return items[0] if items else None
            except requests.HTTPError:
                return None

        data = self._cached(f"am_album:{album_id}", fetch)
        if data is None:
            return None

        attrs = data["attributes"]
        tracks_data = (
            data.get("relationships", {})
            .get("tracks", {})
            .get("data", [])
        )

        return Album(
            id=data["id"],
            name=attrs["name"],
            provider="apple_music",
            release_date=attrs.get("releaseDate", ""),
            total_tracks=attrs.get("trackCount", 0),
            artists=attrs.get("artistName", ""),
            tracks=[
                Track(
                    name=t["attributes"]["name"],
                    duration_ms=t["attributes"].get("durationInMillis", 0),
                )
                for t in tracks_data
            ],
        )

    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        def fetch():
            data = self._get("search", term=query, types="albums", limit=limit)
            return data.get("results", {}).get("albums", {}).get("data", [])

        raw = self._cached(f"am_search_albums:{query.lower()}:{limit}", fetch)
        time.sleep(0.1)
        return [
            Album(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                total_tracks=a["attributes"].get("trackCount", 0),
                artists=a["attributes"].get("artistName", ""),
            )
            for a in raw
        ]

    def clear_cache(self) -> int:
        count = len(self._cache)
        self._cache.clear()
        return count
