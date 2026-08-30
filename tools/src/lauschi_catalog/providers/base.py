"""Abstract provider interface for catalog operations."""

import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field

import requests

from lauschi_catalog.providers._retry import parse_retry_after

DEFAULT_TTL = 7 * 24 * 3600  # 7 days


@dataclass(frozen=True)
class Artist:
    """An artist/series from any provider."""

    id: str
    name: str
    provider: str
    genres: list[str] = field(default_factory=list)
    followers: int = 0
    image_url: str = ""


@dataclass(frozen=True)
class Album:
    """An album (Hörspiel episode) from any provider."""

    id: str
    name: str
    provider: str
    total_tracks: int = 0
    release_date: str = ""
    artists: str = ""
    label: str = ""
    album_type: str = ""  # album | single | compilation | ep
    image_url: str = ""
    tracks: list["Track"] = field(default_factory=list)


@dataclass
class AlbumBatch:
    """Result of a batched album lookup.

    [unverified] holds IDs whose lookup failed even after retries. They
    are NOT missing: absence from [albums] proves nothing for them, so
    callers must never treat them as deleted. Conflating the two would
    let a provider outage look like the catalog rotting.
    """

    albums: list[Album] = field(default_factory=list)
    unverified: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Track:
    """A track within an album."""

    name: str
    duration_ms: int = 0


class CatalogProvider(ABC):
    """Abstract interface for content providers.

    Implementations: SpotifyProvider, AppleMusicProvider.
    Used by discover, curate, and validate commands.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Provider identifier (e.g. 'spotify', 'apple_music')."""

    @abstractmethod
    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        """Search for artists by name."""

    @abstractmethod
    def artist_exists(self, artist_id: str) -> bool:
        """Cheap existence check for an artist id.

        Returns True if the provider knows the id (200), False if it
        returns 404. Other HTTP errors propagate so transient issues
        aren't silently treated as "missing".
        """

    @abstractmethod
    def artist_details(self, artist_id: str) -> Artist | None:
        """Fetch artist metadata by ID. Returns None on 404."""

    @abstractmethod
    def artist_albums(self, artist_id: str) -> list[Album]:
        """Fetch all albums for an artist."""

    @abstractmethod
    def albums_by_ids(self, album_ids: list[str]) -> AlbumBatch:
        """Fetch many albums in as few requests as the provider allows.

        Chunked internally (20 per call on Spotify, 100 on Apple Music).
        IDs the provider no longer knows are absent from
        [AlbumBatch.albums], which makes this an existence check too, but
        only for IDs that are not in [AlbumBatch.unverified]. Tracks are
        not populated; use [album_details] when they are needed.
        """

    @abstractmethod
    def album_details(self, album_id: str) -> Album | None:
        """Fetch full album details including tracks."""

    @abstractmethod
    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        """Search for albums by query."""


# Sentinel cached under the per-album key when the provider answers 404
# (or omits the id from a batch response). diskcache must serialize the
# value, so a module-level marker dict round-trips; a plain None cannot
# be used because ``.get`` returning None already means "key missing",
# which is exactly how gone albums ended up re-requested on every run.
_NOT_FOUND = {"cache": "not found"}


def _is_not_found(value: object) -> bool:
    return value is _NOT_FOUND or value == _NOT_FOUND


class CachedHttpProvider(CatalogProvider):
    """Shared HTTP machinery for the provider implementations.

    Holds the disk cache, the token refresh clock, the GET retry loop
    (429 Retry-After, 401 token rotation, 5xx backoff) and the
    split-and-retry for batched album lookups. Subclasses keep URL
    building, token minting, and row mapping.

    One request loop instead of the two near-identical copies this
    replaces: same three attempts, same order of checks (429, 401, 5xx),
    same outcome on exhaustion. The last attempt falls through to
    ``raise_for_status`` without sleeping.
    """

    #: per-attempt HTTP timeout. Spotify's API survived 20 s; Apple
    #: times out 100-id batches at load, where 15 s fails faster and
    #: the 5xx retry carries the recovery.
    request_timeout: float = 20.0
    #: album ids per batched lookup request (Spotify max 20, Apple 100).
    batch_size: int = 20
    #: cache key prefix for per-id batch rows (no track lists; distinct
    #: from the full album_details entry which carries tracks).
    row_cache_prefix: str = "albums:"

    def __init__(self, *, cache_dir, use_cache: bool = True) -> None:
        import diskcache

        self._cache = diskcache.Cache(str(cache_dir), size_limit=500 * 1024 * 1024)
        self._use_cache = use_cache
        self._token = self._fetch_token()
        self._token_time = time.time()

    def _fetch_token(self) -> str:
        """Mint a fresh auth token. Subclass-specific (OAuth vs JWT)."""
        raise NotImplementedError

    def _ensure_token(self) -> None:
        """Refresh the token if it is older than 55 minutes (expires at 60)."""
        if time.time() - self._token_time > 3300:
            self._token = self._fetch_token()
            self._token_time = time.time()

    def _request(self, url: str, *, params: dict | None = None) -> dict:
        """HTTP GET with token refresh, 429 Retry-After and 5xx backoff.

        Used for catalog endpoints and pagination URLs alike so a
        paginated page neither skips 401 rotation nor silently swallows
        429s.
        """
        self._ensure_token()
        response: requests.Response | None = None
        for attempt in range(3):
            response = requests.get(
                url,
                headers={"Authorization": f"Bearer {self._token}"},
                params=params,
                timeout=self.request_timeout,
            )
            status = response.status_code
            if status == 429 and attempt < 2:
                time.sleep(parse_retry_after(response.headers.get("Retry-After")))
                continue
            if status == 401 and attempt < 2:
                self._token = self._fetch_token()
                self._token_time = time.time()
                continue
            # Transient upstream failures (502/503/504) shouldn't kill a
            # long sweep; the token path already backs off this way.
            if 500 <= status < 600 and attempt < 2:
                time.sleep(2 * 2**attempt)
                continue
            response.raise_for_status()
            return response.json()
        response.raise_for_status()
        return {}  # unreachable, raise_for_status throws

    def _cached(self, key: str, fetch):
        """Cache-through fetch with the run-wide TTL.

        Writes are skipped on no-cache runs: a caller that asked to
        bypass the cache does not want it warmed either.
        """
        if self._use_cache:
            cached = self._cache.get(key)
            if cached is not None:
                return cached
        result = fetch()
        if self._use_cache:
            self._cache.set(key, result, expire=DEFAULT_TTL)
        return result

    def artist_exists(self, artist_id: str) -> bool:
        """Cheap existence check, derived from artist_details.

        Both providers answer 404 for a dead artist id; other HTTP
        errors propagate so a transient outage is never treated as
        "missing".
        """
        return self.artist_details(artist_id) is not None

    def album_rows(self, data: dict) -> list[dict]:
        """Raw album rows in a batch response (subclass mapping)."""
        raise NotImplementedError

    def raw_to_album(self, raw: dict) -> Album:
        """Map one raw batch row to an Album (subclass mapping)."""
        raise NotImplementedError

    def _album_chunk_url(self, ids: list[str]) -> str:
        """URL of the batched album lookup endpoint (subclass mapping)."""
        raise NotImplementedError

    def albums_by_ids(self, album_ids: list[str]) -> AlbumBatch:
        """Batch album lookup with per-id cache rows.

        Previously one cache entry keyed by the exact id chunk: a chunk
        with one id changed never hit the cache again, and gone albums
        were re-requested on every run. Now each id is cached under its
        own key, a 404 answers with a sentinel (so a gone album is
        verified once per TTL, then answered from cache), and a chunk
        that keeps failing splits in half so one bad batch costs a few
        ids instead of twenty. ids that still fail land in
        [AlbumBatch.unverified], never in "missing".
        """
        batch = AlbumBatch()
        seen: set[str] = set()
        missing: list[str] = []
        for album_id in album_ids:
            if album_id in seen:
                continue
            seen.add(album_id)
            hit = (
                self._cache.get(f"{self.row_cache_prefix}{album_id}")
                if self._use_cache
                else None
            )
            if hit is None:
                missing.append(album_id)
            elif _is_not_found(hit):
                continue  # known gone; absence from .albums means it
            else:
                batch.albums.append(self.raw_to_album(hit))

        def fetch_missing(chunk: list[str]) -> None:
            try:
                data = self._cached(
                    _chunk_cache_key(self.row_cache_prefix, chunk),
                    lambda: self._request(
                        self._album_chunk_url(chunk),
                        params=self._album_chunk_params(chunk),
                    ),
                )
            except requests.HTTPError, requests.ConnectionError, requests.Timeout:
                if len(chunk) == 1:
                    batch.unverified.extend(chunk)
                    return
                mid = len(chunk) // 2
                fetch_missing(chunk[:mid])
                fetch_missing(chunk[mid:])
                return

            returned = {row["id"] for row in self.album_rows(data) if row.get("id")}
            for raw in self.album_rows(data):
                album = self.raw_to_album(raw)
                batch.albums.append(album)
                if self._use_cache:
                    self._cache.set(
                        f"{self.row_cache_prefix}{album.id}", raw, expire=DEFAULT_TTL
                    )
            for gone in set(chunk) - returned:
                if self._use_cache:
                    self._cache.set(
                        f"{self.row_cache_prefix}{gone}", _NOT_FOUND, expire=DEFAULT_TTL
                    )

        for i in range(0, len(missing), self.batch_size):
            fetch_missing(missing[i : i + self.batch_size])
        return batch

    def clear_cache(self) -> int:
        count = len(self._cache)
        self._cache.clear()
        return count


def _chunk_cache_key(prefix: str, chunk: list[str]) -> str:
    return f"{prefix}chunk:{','.join(chunk)}"
