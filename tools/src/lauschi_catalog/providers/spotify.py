"""Spotify provider with disk caching."""

from __future__ import annotations

import os
import sys
import time

import diskcache
import requests

from lauschi_catalog.catalog.paths import cache_dir
from lauschi_catalog.providers._retry import parse_retry_after
from lauschi_catalog.providers.base import Album, Artist, CatalogProvider, Track

CACHE_DIR = cache_dir("spotify")
DEFAULT_TTL = 7 * 24 * 3600  # 7 days


def _pick_image(images: list[dict]) -> str:
    """Pick a ~300px image URL from Spotify's images array (sorted largest-first)."""
    if not images:
        return ""
    for img in images:
        if img.get("width", 0) <= 300:
            return img.get("url", "")
    return images[-1].get("url", "")


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
        """Get a fresh client credentials token.

        Retries on transient infrastructure failures so a brief
        Spotify hiccup doesn't crash the entire provider on
        construction. Two failure modes seen in a 26-entry catalog
        loop:
          - 503 Service Unavailable from accounts.spotify.com
          - ReadTimeout against the same endpoint

        Both were transient, but the original 3-attempt budget
        (1+2+4 = 7s) wasn't enough for a sustained wobble: two
        entries in a later 18-entry retry loop still died on 503.
        Bumped to 5 attempts with doubled base sleep
        (2+4+8+16+32 = 62s), which covers an outage of about a
        minute before giving up.

        Retries: ConnectionError, Timeout, HTTP 429, HTTP 5xx.
        Does NOT retry: 400/401/403 — those are bad-credentials
        errors that won't fix themselves.
        """
        max_attempts = 5
        for attempt in range(max_attempts):
            try:
                r = requests.post(
                    "https://accounts.spotify.com/api/token",
                    data={
                        "grant_type": "client_credentials",
                        "client_id": self._cid,
                        "client_secret": self._csec,
                    },
                    timeout=10,
                )
            except (requests.ConnectionError, requests.Timeout):
                if attempt == max_attempts - 1:
                    raise
                time.sleep(2 * 2 ** attempt)
                continue

            if r.status_code == 429 and attempt < max_attempts - 1:
                time.sleep(parse_retry_after(r.headers.get("Retry-After")))
                continue
            if 500 <= r.status_code < 600 and attempt < max_attempts - 1:
                time.sleep(2 * 2 ** attempt)
                continue

            r.raise_for_status()
            return r.json()["access_token"]
        # All attempts saw a retryable response; surface the last
        # one as a real error so the caller knows what failed.
        r.raise_for_status()
        return ""  # unreachable

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
                # Honor Retry-After in any of the spec-allowed forms
                # (delta-seconds int, float, or HTTP-date). Same helper
                # apple_music uses; previous int(...) crashed on
                # non-integer values.
                time.sleep(parse_retry_after(r.headers.get("Retry-After")))
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

    def artist_exists(self, artist_id: str) -> bool:
        try:
            self._get(f"artists/{artist_id}")
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 404:
                return False
            raise
        return True

    def artist_details(self, artist_id: str) -> Artist | None:
        try:
            a = self._get(f"artists/{artist_id}")
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 404:
                return None
            raise
        return Artist(
            id=a["id"],
            name=a["name"],
            provider="spotify",
            genres=a.get("genres", []),
            followers=a.get("followers", {}).get("total", 0)
            if isinstance(a.get("followers"), dict)
            else a.get("followers", 0),
            image_url=_pick_image(a.get("images", [])),
        )

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
                image_url=_pick_image(a.get("images", [])),
            )
            for a in raw
        ]

    def artist_albums(self, artist_id: str) -> list[Album]:
        def fetch():
            # First page carries the query params; pagination URLs from
            # ``data["next"]`` already encode them, so subsequent calls
            # pass no params. Splitting the first call out reads cleaner
            # than the reset-to-{} pattern.
            # The filter param is include_groups; album_type is only a
            # response field and gets silently ignored as a query param,
            # which floods the result with appears_on albums (other
            # artists' releases this artist features on).
            data = self._get(
                f"artists/{artist_id}/albums",
                market="DE", limit=50,
                include_groups="album,single,compilation",
            )
            raw: list[dict] = list(data.get("items", []))
            url = data.get("next") or ""
            while url:
                time.sleep(0.05)
                data = self._get(url)
                raw.extend(data.get("items", []))
                url = data.get("next") or ""
            return raw

        raw = self._cached(f"artist_albums:{artist_id}", fetch)
        return [
            Album(
                id=a["id"],
                name=a["name"],
                provider="spotify",
                release_date=a.get("release_date", ""),
                total_tracks=a.get("total_tracks", 0),
                album_type=a.get("album_type", ""),
                image_url=_pick_image(a.get("images", [])),
            )
            for a in raw
            # Safety net for cache entries fetched before the
            # include_groups fix: drop appears_on items here too.
            if a.get("album_group") != "appears_on"
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
            album_type=data.get("album_type", ""),
            image_url=_pick_image(data.get("images", [])),
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
                image_url=_pick_image(a.get("images", [])),
            )
            for a in raw
        ]

    def clear_cache(self) -> int:
        count = len(self._cache)
        self._cache.clear()
        return count
