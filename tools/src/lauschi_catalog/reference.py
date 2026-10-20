"""Public reference index: an outside, publisher-fed catalog of Hörspiel
series, their lines and the numbering inside each line.

The index's own wire format stays out of this repo. `REFERENCE_INDEX_SOURCE`
in `.env` names a Python file on your machine whose `source()` returns a
`ReferenceSource`, and this module caches and matches what it returns.
Without it the index reports itself unconfigured and every lookup says so;
nothing else in the pipeline changes. Answers are cached for seven days
under `.cache/reference/`.

Good for: which line of a brand an album belongs to, the number an
episode carries inside its line when the provider title carries none,
and the names of a brand's lines when a split is proposed. Not good
for completeness: it lags behind new releases and lists only what its
owner licenses, so an absent title proves nothing.

The index also holds products it files under no line. A brand's lines
do not show them, so they are read through the product search
(``products``, ``without_a_line``): a title missing from every line may
still be a product of the brand.
"""

import importlib.util
import os
import re
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from lauschi_catalog.catalog.paths import cache_dir

_TTL_SECONDS = 7 * 24 * 3600


@dataclass(frozen=True)
class ReferenceEpisode:
    number: str | None
    title: str
    seconds: int | None
    #: the product (release) the episode is part of; several episodes
    #: can share one, like two stories on one album
    product: int | None = None


@dataclass(frozen=True)
class ReferenceLine:
    name: str
    episodes: list[ReferenceEpisode]


@dataclass(frozen=True)
class ReferenceSeries:
    id: int
    name: str
    lines: list[ReferenceLine]


@dataclass(frozen=True)
class ReferenceProduct:
    """One release in the index. ``brand`` is None for a product the
    index files under no brand, and then ``line`` and ``number`` are too.
    A filed product can still come without a line name."""

    id: int
    title: str
    author: str
    label: str
    #: the index's word for the kind of release (Hörspiel, audiobook, music)
    kind: str
    seconds: int | None
    categories: tuple[str, ...]
    brand: str | None
    line: str | None
    number: str | None
    #: the release's EAN or ISBN-13, the barcode the stores give it too
    barcode: str = ""


def _key(name: str) -> str:
    """Matching key for a series name: case, punctuation and spacing folded."""
    text = unicodedata.normalize("NFC", name).lower()
    text = re.sub(r"[^a-z0-9äöüß]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


class ReferenceSource(Protocol):
    """Where the index's answers come from. Each call may be a request,
    `ReferenceIndex` caches them."""

    def names(self) -> dict[int, str]:
        """Every series in the index, id to name."""
        ...

    def series(self, series_id: int) -> ReferenceSeries:
        """One series with its lines and their episodes."""
        ...

    def products(self, query: str) -> list[ReferenceProduct]:
        """The products a full-text search finds, in a line or not."""
        ...

    def barcodes(self, series_id: int) -> dict[int, str]:
        """The barcode of each product a series files, by product id,
        leaving out products without one."""
        ...


def load_source() -> ReferenceSource | None:
    """The source `REFERENCE_INDEX_SOURCE` points to, or None when it is
    not set. A path that is set but does not load is an error, not an
    unconfigured index."""
    path = os.environ.get("REFERENCE_INDEX_SOURCE", "").strip()
    if not path:
        return None
    spec = importlib.util.spec_from_file_location(
        "lauschi_reference_source", Path(path).expanduser()
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(
            f"REFERENCE_INDEX_SOURCE does not name a Python file: {path}"
        )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.source()


class ReferenceIndex:
    """Cached access to the public reference index."""

    def __init__(
        self,
        source: ReferenceSource | None = None,
        *,
        cache_root: Path | None = None,
        use_cache: bool = True,
    ) -> None:
        """Without a ``source`` the index loads the one the environment
        names, and stays unconfigured when there is none."""
        self._source = source if source is not None else load_source()
        self._use_cache = use_cache and self._source is not None
        self._cache_root = cache_root
        self._cache = None

    @property
    def configured(self) -> bool:
        return self._source is not None

    def _store(self):
        if self._cache is None:
            # diskcache is deferred like in the provider clients: it is
            # only needed once a configured index is actually queried.
            import diskcache

            root = self._cache_root or cache_dir("reference")
            self._cache = diskcache.Cache(str(root), size_limit=100 * 1024 * 1024)
        return self._cache

    def _cached[T](self, key: str, fetch: Callable[[], T]) -> T:
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
        """Every series in the index, id to name. Cached."""
        if self._source is None:
            return {}
        return self._cached("names", self._source.names)

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
        if self._source is None:
            raise RuntimeError("The reference index is not configured.")
        source = self._source
        return self._cached(f"lines:{series_id}", lambda: source.series(series_id))

    def lines_for(self, query: str) -> ReferenceSeries | None:
        """The best-matching series with its lines, or None."""
        hits = self.find(query)
        return self.series(hits[0][0]) if hits else None

    def products(self, query: str) -> list[ReferenceProduct]:
        """Products the index's full-text search finds for a query,
        whether they sit in a line or not. Cached per query."""
        if self._source is None or not _key(query):
            return []
        source = self._source
        return self._cached(f"releases:{_key(query)}", lambda: source.products(query))

    def barcodes(self, series_id: int) -> dict[int, str]:
        """The barcode of each product a series files, by product id.
        Cached. A product without one is left out."""
        if self._source is None:
            return {}
        source = self._source
        return self._cached(
            f"product_barcodes:{series_id}", lambda: source.barcodes(series_id)
        )

    def without_a_line(self, series: ReferenceSeries) -> list[ReferenceProduct]:
        """A brand's products that the index files under no line.

        Such a product is filed under no brand at all, so it is found by
        the full-text search and counts only when it names the brand: as
        its author, in its title, or as a category. An unfiled copy of a
        release that is filed is left out. Which line the rest belong to
        the index does not say.
        """
        brand = _key(series.name)
        hits = self.products(series.name)
        filed = {_key(product.title) for product in hits if product.brand}
        return [
            product
            for product in hits
            if product.brand is None
            and _key(product.title) not in filed
            and (
                _key(product.author) == brand
                or brand in _key(product.title)
                or brand in {_key(c) for c in product.categories}
            )
        ]
