"""Deletion log for catalog series.

Tracks series_ids that have been intentionally removed from the
catalog. `catalog-add` consults this log so an AI agent (or a tired
human) doesn't silently re-introduce a series we deliberately
dropped.

Format: assets/catalog/deleted.json, one top-level key ``deleted``
holding a list of records, each on one line::

    {
      "deleted": [
        {"id": "tom_turbo", "title": "Tom Turbo", "reason": "No streaming presence in the Hörspiel-album format.", "deleted_at": "2026-05-13T11:42:00+00:00"}
      ]
    }

Entries are append-only by convention. ``catalog-add --force-readd``
removes an entry when an operator explicitly chooses to re-introduce
the series.
"""

from datetime import UTC, datetime
from pathlib import Path

from lauschi_catalog.catalog import io
from lauschi_catalog.catalog.paths import deleted_log_path


def _resolve(path: Path | None) -> Path:
    """Call-time resolution so LAUSCHI_REPO_ROOT overrides always work."""
    return path if path is not None else deleted_log_path()


def load_deleted(path: Path | None = None) -> list[dict]:
    """The deletion records, none while the log does not exist."""
    target = _resolve(path)
    return io.load_raw(target)["deleted"] if target.exists() else []


def is_deleted(series_id: str, path: Path | None = None) -> dict | None:
    """If ``series_id`` is in the log, return its record; else None."""
    for entry in load_deleted(path):
        if entry.get("id") == series_id:
            return entry
    return None


def record_deletion(
    series_id: str,
    title: str,
    reason: str,
    *,
    path: Path | None = None,
) -> None:
    """Append a deletion record to the log.

    The reason is required so future readers (and future curate
    agents) can decide whether a re-add proposal is sensible.
    """
    # Idempotent: if the id is already logged, refresh its timestamp.
    entries = [e for e in load_deleted(path) if e.get("id") != series_id]
    entries.append(
        {
            "id": series_id,
            "title": title,
            "reason": reason,
            "deleted_at": datetime.now(UTC).isoformat(timespec="seconds"),
        },
    )
    io.write_catalog(_resolve(path), {"deleted": entries})


def remove_from_deleted(series_id: str, *, path: Path | None = None) -> bool:
    """Drop ``series_id`` from the log. Returns True if removed.

    Used by ``catalog-add --force-readd`` to explicitly clear the log
    entry when an operator chooses to re-introduce the series.
    """
    entries = load_deleted(path)
    kept = [e for e in entries if e.get("id") != series_id]
    if len(kept) == len(entries):
        return False
    io.write_catalog(_resolve(path), {"deleted": kept})
    return True
