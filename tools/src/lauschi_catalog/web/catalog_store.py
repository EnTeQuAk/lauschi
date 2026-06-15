"""In-process catalog store backed by series.yaml.

Replaces the former SQLite cache. Loads YAML into a dict on startup;
all reads are dict lookups. Call ``reload_catalog()`` after any write
to series.yaml to refresh the in-process state.
"""

from __future__ import annotations

import threading

from filelock import FileLock

from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import series_lock_path, series_yaml_path

_lock = threading.Lock()
_by_id: dict[str, CatalogEntry] = {}
_ordered: list[CatalogEntry] = []


def reload_catalog() -> int:
    """Reload series.yaml into memory. Returns entry count."""
    with FileLock(str(series_lock_path())):
        entries = load_catalog(series_yaml_path())
    with _lock:
        _by_id.clear()
        for e in entries:
            _by_id[e.id] = e
        _ordered[:] = sorted(entries, key=lambda e: e.title.lower())
    return len(entries)


def get_all_series() -> list[CatalogEntry]:
    """Return all series sorted by title (case-insensitive)."""
    with _lock:
        return list(_ordered)


def get_series_by_id(series_id: str) -> CatalogEntry | None:
    """Look up a single series by ID."""
    with _lock:
        return _by_id.get(series_id)
