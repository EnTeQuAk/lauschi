"""Public line index: an outside, publisher-fed catalog of Hörspiel
series, their lines and the numbering inside each line.

Configured by REFERENCE_INDEX_URL, the API base URL, kept in `.env`
like the provider keys. Without it the index reports itself
unconfigured and every lookup says so; nothing else in the pipeline
changes. Responses are cached for seven days under `.cache/reference/`.

Good for: which line of a brand an album belongs to, the number an
episode carries inside its line when the provider title carries none,
and the names of a brand's lines when a split is proposed. Not good
for completeness: it lags behind new releases and lists only what its
owner licenses, so an absent title proves nothing.
"""

import os
import re
import time
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import requests

from lauschi_catalog.catalog.paths import cache_dir

_TTL_SECONDS = 7 * 24 * 3600
_PAGE_SIZE = 50

Fetch = Callable[[str, dict | None], dict]


@dataclass(frozen=True)
class ReferenceEpisode:
    number: str | None
    title: str
    seconds: int | None


@dataclass(frozen=True)
class ReferenceLine:
    name: str
    episodes: list[ReferenceEpisode]


@dataclass(frozen=True)
class ReferenceSeries:
    id: int
    name: str
    lines: list[ReferenceLine]


def _key(name: str) -> str:
    """Matching key for a series name: case, punctuation and spacing folded."""
    text = unicodedata.normalize("NFC", name).lower()
    text = re.sub(r"[^a-z0-9äöüß]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _int(value: object) -> int | None:
    try:
        return int(str(value).strip())
    except TypeError, ValueError:
        return None


def _http_get(url: str, params: dict | None) -> dict:
    """GET with a short 5xx backoff. The index is public, no token."""
    response: requests.Response | None = None
    for attempt in range(3):
        response = requests.get(url, params=params, timeout=20)
        if 500 <= response.status_code < 600 and attempt < 2:
            time.sleep(2 * 2**attempt)
            continue
        response.raise_for_status()
        return response.json()
    assert response is not None
    response.raise_for_status()
    return {}


def _parse_series(data: dict) -> ReferenceSeries:
    lines: list[ReferenceLine] = []
    for season in data.get("seasons") or []:
        episodes = [
            ReferenceEpisode(
                number=(str(e["episodeNumber"]).strip() or None)
                if e.get("episodeNumber") is not None
                else None,
                title=str(e.get("episodeTitle") or "").strip(),
                seconds=_int(e.get("length")),
            )
            for e in season.get("episodes") or []
        ]
        lines.append(
            ReferenceLine(name=str(season.get("name") or "").strip(), episodes=episodes)
        )
    return ReferenceSeries(
        id=int(data["id"]), name=str(data.get("name") or "").strip(), lines=lines
    )


class ReferenceIndex:
    """Cached client for the public line index."""

    def __init__(
        self,
        base_url: str | None = None,
        *,
        fetch: Fetch = _http_get,
        cache_root: Path | None = None,
        use_cache: bool = True,
    ) -> None:
        url = (
            base_url
            if base_url is not None
            else os.environ.get("REFERENCE_INDEX_URL", "")
        )
        self._base = url.rstrip("/")
        self._fetch = fetch
        self._use_cache = use_cache and bool(self._base)
        self._cache_root = cache_root
        self._cache = None

    @property
    def configured(self) -> bool:
        return bool(self._base)

    def _store(self):
        if self._cache is None:
            # diskcache is deferred like in the provider clients: it is
            # only needed once a configured index is actually queried.
            import diskcache

            root = self._cache_root or cache_dir("reference")
            self._cache = diskcache.Cache(str(root), size_limit=100 * 1024 * 1024)
        return self._cache

    def _cached(self, key: str, fetch: Callable[[], object]) -> object:
        if not self._use_cache:
            return fetch()
        store = self._store()
        hit = store.get(key)
        if hit is not None:
            return hit
        value = fetch()
        store.set(key, value, expire=_TTL_SECONDS)
        return value

    def names(self) -> dict[int, str]:
        """Every series in the index, id to name. One paged sweep, cached."""
        if not self.configured:
            return {}
        return self._cached("names", self._fetch_names)  # type: ignore[return-value]

    def _fetch_names(self) -> dict[int, str]:
        names: dict[int, str] = {}
        page = 0
        while True:
            data = self._fetch(
                f"{self._base}/series", {"page": page, "size": _PAGE_SIZE}
            )
            for item in data.get("_embedded", {}).get("series", []):
                names[int(item["id"])] = str(item.get("name") or "").strip()
            page += 1
            if page >= int((data.get("page") or {}).get("totalPages", 0)):
                return names

    def find(self, query: str) -> list[tuple[int, str]]:
        """Series matching a name: exact key matches first, then the
        names containing the query or contained in it, shortest first."""
        wanted = _key(query)
        if not wanted:
            return []
        exact: list[tuple[int, str]] = []
        partial: list[tuple[int, str]] = []
        for sid, name in self.names().items():
            key = _key(name)
            if key == wanted:
                exact.append((sid, name))
            elif wanted in key or key in wanted:
                partial.append((sid, name))
        partial.sort(key=lambda hit: len(hit[1]))
        return exact + partial

    def series(self, series_id: int) -> ReferenceSeries:
        data = self._cached(
            f"series:{series_id}",
            lambda: self._fetch(f"{self._base}/series/{series_id}", None),
        )
        return _parse_series(data)  # type: ignore[arg-type]

    def lines_for(self, query: str) -> ReferenceSeries | None:
        """The best-matching series with its lines, or None."""
        hits = self.find(query)
        return self.series(hits[0][0]) if hits else None
