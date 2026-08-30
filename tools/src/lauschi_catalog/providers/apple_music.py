"""Apple Music provider with disk caching."""

import time

import jwt
import requests

from lauschi_catalog.catalog.paths import cache_dir, repo_root
from lauschi_catalog.providers.base import (
    _NOT_FOUND,
    Album,
    Artist,
    CachedHttpProvider,
    Track,
    _is_not_found,
)

CACHE_DIR = cache_dir("apple_music")
KEY_PATH = repo_root() / "android" / "app" / "AuthKey_PWHK2R76T9.p8"


def _pick_artwork(attrs: dict, size: int = 300) -> str:
    """Resolve Apple Music artwork URL template to a concrete URL."""
    artwork = attrs.get("artwork", {})
    url = artwork.get("url", "")
    if not url:
        return ""
    return url.replace("{w}", str(size)).replace("{h}", str(size))


# MusicKit config
TEAM_ID = "QDF8U52UF4"
KEY_ID = "PWHK2R76T9"
STOREFRONT = "de"


class AppleMusicProvider(CachedHttpProvider):
    """Apple Music API with transparent disk caching and auto token refresh."""

    request_timeout = 15.0  # Apple Music times out on large batches under load
    batch_size = 100  # 300 is rejected
    row_cache_prefix = "apple_music:albums:"

    def __init__(self, *, use_cache: bool = True) -> None:
        super().__init__(cache_dir=CACHE_DIR, use_cache=use_cache)

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

    def _fetch_token(self) -> str:
        return self._generate_token()

    def _get(self, path: str, **params) -> dict:
        """Catalog endpoint GET with retry, token refresh, rate-limit handling."""
        url = f"https://api.music.apple.com/v1/catalog/{STOREFRONT}/{path}"
        return self._request(url, params=params or None)

    def artist_details(self, artist_id: str) -> Artist | None:
        try:
            data = self._get(f"artists/{artist_id}")
        except requests.HTTPError as e:
            if e.response is not None and e.response.status_code == 404:
                return None
            raise
        items = data.get("data", [])
        if not items:
            return None
        a = items[0]
        attrs = a.get("attributes", {})
        return Artist(
            id=a["id"],
            name=attrs.get("name", ""),
            provider="apple_music",
            genres=attrs.get("genreNames", []),
            image_url=_pick_artwork(attrs),
        )

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        def fetch():
            # Throttle live API calls only. The previous unconditional
            # sleep after _cached() also paid the 100ms cost on cache
            # hits — ~17s wasted across a 171-series validate run.
            data = self._get("search", term=query, types="artists", limit=limit)
            time.sleep(0.1)
            return data.get("results", {}).get("artists", {}).get("data", [])

        raw = self._cached(f"am_search_artists:{query.lower()}:{limit}", fetch)
        return [
            Artist(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                genres=a["attributes"].get("genreNames", []),
                image_url=_pick_artwork(a.get("attributes", {})),
            )
            for a in raw
        ]

    # The artist's own output. The plain `albums` relationship also
    # includes albums where the artist is only feature-credited (e.g.
    # the "Kinderlied für dich" personalized-name factory albums
    # "feat. Simone Sommerland"), which flooded discographies. The
    # appears-on-albums view isolates those and is deliberately absent.
    _OWN_RELEASE_VIEWS = (
        "full-albums",
        "singles",
        "compilation-albums",
        "live-albums",
    )

    def artist_albums(self, artist_id: str) -> list[Album]:
        def fetch():
            # Apple Music paginates at 25 by default, max 100.
            all_albums: list[dict] = []
            seen_ids: set[str] = set()
            for view in self._OWN_RELEASE_VIEWS:
                try:
                    data = self._get(
                        f"artists/{artist_id}/view/{view}",
                        limit=100,
                    )
                except requests.HTTPError as e:
                    # Artists without e.g. live albums 404 on that view.
                    if e.response is not None and e.response.status_code == 404:
                        continue
                    raise
                while True:
                    for a in data.get("data", []):
                        if a["id"] in seen_ids:
                            continue
                        seen_ids.add(a["id"])
                        all_albums.append(a)
                    # Follow pagination through _request so token refresh
                    # and 429 handling apply on every page.
                    next_url = data.get("next")
                    if not next_url:
                        break
                    time.sleep(0.1)
                    data = self._request(
                        f"https://api.music.apple.com{next_url}",
                    )
                time.sleep(0.1)
            return all_albums

        raw = self._cached(f"am_artist_albums:{artist_id}", fetch)
        return [
            Album(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                release_date=a["attributes"].get("releaseDate", ""),
                total_tracks=a["attributes"].get("trackCount", 0),
                artists=a["attributes"].get("artistName", ""),
                image_url=_pick_artwork(a.get("attributes", {})),
            )
            for a in raw
        ]

    def album_details(self, album_id: str) -> Album | None:
        def fetch():
            time.sleep(0.1)
            try:
                data = self._get(f"albums/{album_id}", include="tracks")
                items = data.get("data", [])
                return items[0] if items else _NOT_FOUND
            except requests.HTTPError as e:
                status = e.response.status_code if e.response is not None else None
                if status == 404:
                    return _NOT_FOUND
                raise

        data = self._cached(f"am_album:{album_id}", fetch)
        if data is None or _is_not_found(data):
            return None

        attrs = data["attributes"]
        tracks_data = data.get("relationships", {}).get("tracks", {}).get("data", [])

        # Derive album_type from Apple Music flags
        am_type = ""
        if attrs.get("isSingle"):
            am_type = "single"
        elif attrs.get("isCompilation"):
            am_type = "compilation"
        elif attrs.get("trackCount", 0) <= 5:
            am_type = "ep"
        else:
            am_type = "album"

        return Album(
            id=data["id"],
            name=attrs["name"],
            provider="apple_music",
            release_date=attrs.get("releaseDate", ""),
            total_tracks=attrs.get("trackCount", 0),
            artists=attrs.get("artistName", ""),
            album_type=am_type,
            image_url=_pick_artwork(attrs),
            tracks=[
                Track(
                    name=t["attributes"]["name"],
                    duration_ms=t["attributes"].get("durationInMillis", 0),
                )
                for t in tracks_data
            ],
        )

    def album_rows(self, data: dict) -> list[dict]:
        return (data or {}).get("data") or []

    def raw_to_album(self, raw: dict) -> Album:
        attrs = raw.get("attributes") or {}
        return Album(
            id=raw["id"],
            name=attrs.get("name", ""),
            provider="apple_music",
            release_date=attrs.get("releaseDate", ""),
            total_tracks=attrs.get("trackCount", 0),
            artists=attrs.get("artistName", ""),
            image_url=_pick_artwork(attrs),
        )

    def _album_chunk_url(self, ids: list[str]) -> str:
        return f"https://api.music.apple.com/v1/catalog/{STOREFRONT}/albums"

    def _album_chunk_params(self, ids: list[str]) -> dict:
        return {"ids": ",".join(ids)}

    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        def fetch():
            data = self._get("search", term=query, types="albums", limit=limit)
            time.sleep(0.1)
            return data.get("results", {}).get("albums", {}).get("data", [])

        raw = self._cached(f"am_search_albums:{query.lower()}:{limit}", fetch)
        return [
            Album(
                id=a["id"],
                name=a["attributes"]["name"],
                provider="apple_music",
                total_tracks=a["attributes"].get("trackCount", 0),
                artists=a["attributes"].get("artistName", ""),
                image_url=_pick_artwork(a.get("attributes", {})),
            )
            for a in raw
        ]
