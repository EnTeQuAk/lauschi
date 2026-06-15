"""In-process catalog store backed by series.yaml.

Replaces the former SQLite cache. Loads YAML into a dict on startup;
all reads are dict lookups. Call ``reload_catalog()`` after any write
to series.yaml to refresh the in-process state.

Uses atomic reference swap for the read path so readers never block.
Only the writer (``reload_catalog``) acquires a lock, and only to
serialize concurrent reloads against each other.
"""

from __future__ import annotations

import threading

from filelock import FileLock

from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import series_lock_path, series_yaml_path

_CatalogState = tuple[dict[str, CatalogEntry], list[CatalogEntry]]

_write_lock = threading.Lock()
_state: _CatalogState = ({}, [])


def reload_catalog() -> int:
    """Reload series.yaml into memory. Returns entry count."""
    global _state
    with FileLock(str(series_lock_path())):
        entries = load_catalog(series_yaml_path())
    by_id = {e.id: e for e in entries}
    ordered = sorted(entries, key=lambda e: e.title.lower())
    with _write_lock:
        _state = (by_id, ordered)
    return len(entries)


def get_all_series() -> list[CatalogEntry]:
    """Return all series sorted by title (case-insensitive)."""
    _, ordered = _state
    return list(ordered)


def get_series_by_id(series_id: str) -> CatalogEntry | None:
    """Look up a single series by ID."""
    by_id, _ = _state
    return by_id.get(series_id)
