"""Deletion log for catalog series.

Tracks series_ids that have been intentionally removed from the
catalog. `catalog-add` consults this log so an AI agent (or a tired
human) doesn't silently re-introduce a series we deliberately
dropped.

Format: a YAML file with one top-level key ``deleted``, holding a list
of entries::

    deleted:
      - id: tom_turbo
        title: Tom Turbo
        reason: No streaming presence in the Hörspiel-album format.
        deleted_at: 2026-05-13T11:42:00+00:00

Entries are append-only by convention. ``catalog-add --force-readd``
removes an entry when an operator explicitly chooses to re-introduce
the series.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from ruamel.yaml import YAML

from lauschi_catalog.catalog.paths import deleted_yaml_path

DELETED_YAML = deleted_yaml_path()

_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.width = 200


def _resolve(path: Path | None) -> Path:
    # The module-level DELETED_YAML is resolved at call time (not bound
    # as a default) so monkeypatching the module attribute in tests
    # actually takes effect.
    return path if path is not None else DELETED_YAML


def _load(path: Path | None = None) -> dict:
    target = _resolve(path)
    if not target.exists():
        return {"deleted": []}
    data = _yaml.load(target)
    if not data or "deleted" not in data:
        return {"deleted": []}
    return data


def load_deleted(path: Path | None = None) -> list[dict]:
    """Return the list of deletion records (or an empty list)."""
    return list(_load(path).get("deleted") or [])


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
    data = _load(path)
    entries = data.get("deleted") or []
    # Idempotent: if the id is already logged, refresh its timestamp.
    entries = [e for e in entries if e.get("id") != series_id]
    entries.append(
        {
            "id": series_id,
            "title": title,
            "reason": reason,
            "deleted_at": datetime.now(UTC).isoformat(timespec="seconds"),
        },
    )
    data["deleted"] = entries
    with _resolve(path).open("w") as f:
        _yaml.dump(data, f)


def remove_from_deleted(series_id: str, *, path: Path | None = None) -> bool:
    """Drop ``series_id`` from the log. Returns True if removed.

    Used by ``catalog-add --force-readd`` to explicitly clear the log
    entry when an operator chooses to re-introduce the series.
    """
    data = _load(path)
    entries = data.get("deleted") or []
    new_entries = [e for e in entries if e.get("id") != series_id]
    if len(new_entries) == len(entries):
        return False
    data["deleted"] = new_entries
    with _resolve(path).open("w") as f:
        _yaml.dump(data, f)
    return True
