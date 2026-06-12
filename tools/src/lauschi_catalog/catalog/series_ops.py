"""Series-level catalog operations.

Pure business logic for editing, deleting, and adding series entries.
No HTTP, no CLI, no console output.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from filelock import FileLock

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.deleted import record_deletion
from lauschi_catalog.catalog.io import safe_write_json, safe_write_yaml
from lauschi_catalog.catalog.loader import load_catalog, load_raw


@dataclass
class SeriesChanges:
    """Requested changes to a series. None means "don't change"."""

    title: str | None = None
    id: str | None = None
    aliases: list[str] | None = None
    episode_pattern: str | list[str] | None = None
    content_type: str | None = None


@dataclass
class EditResult:
    ok: bool
    series_id: str
    error: str | None = None


def validate_series_changes(
    series_id: str,
    changes: SeriesChanges,
) -> list[str]:
    """Validate proposed changes, returning a list of error messages (empty if valid)."""
    errors: list[str] = []

    if changes.id is not None:
        if not re.match(r"^[a-z][a-z0-9_]*$", changes.id):
            errors.append("id must be snake_case")
        else:
            existing_ids = [e.id for e in load_catalog() if e.id != series_id]
            if changes.id in existing_ids:
                errors.append(f"id '{changes.id}' already exists")

    if changes.episode_pattern is not None:
        patterns = (
            [changes.episode_pattern]
            if isinstance(changes.episode_pattern, str)
            else changes.episode_pattern
        )
        for p in patterns:
            try:
                compiled = re.compile(p)
                if compiled.groups < 1:
                    errors.append(f"pattern {p!r} needs at least 1 capture group")
            except re.error as exc:
                errors.append(f"invalid regex {p!r}: {exc}")

    if changes.content_type is not None and changes.content_type not in (
        "hoerspiel",
        "music",
    ):
        errors.append("content_type must be 'hoerspiel' or 'music'")

    return errors


def edit_series(series_id: str, changes: SeriesChanges) -> EditResult:
    """Edit a series in series.yaml. Returns the (possibly new) series id."""
    errors = validate_series_changes(series_id, changes)
    if errors:
        return EditResult(ok=False, series_id=series_id, error="; ".join(errors))

    yaml_path = paths.series_yaml_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(yaml_path)
        raw_entry = None
        for entry in data["series"]:
            if entry.get("id") == series_id:
                raw_entry = entry
                break

        if raw_entry is None:
            return EditResult(
                ok=False,
                series_id=series_id,
                error="series not found in series.yaml",
            )

        if changes.title is not None:
            raw_entry["title"] = changes.title
        if changes.id is not None:
            raw_entry["id"] = changes.id
        if changes.aliases is not None:
            if changes.aliases:
                raw_entry["aliases"] = changes.aliases
            elif "aliases" in raw_entry:
                del raw_entry["aliases"]
        if changes.episode_pattern is not None:
            if changes.episode_pattern:
                raw_entry["episode_pattern"] = changes.episode_pattern
            elif "episode_pattern" in raw_entry:
                del raw_entry["episode_pattern"]
        if changes.content_type is not None:
            if changes.content_type != "hoerspiel":
                raw_entry["content_type"] = changes.content_type
            elif "content_type" in raw_entry:
                del raw_entry["content_type"]

        safe_write_yaml(yaml_path, data)

    new_id = changes.id
    if new_id and new_id != series_id:
        old_curation = paths.curation_path(series_id)
        new_curation = paths.curation_path(new_id)
        if old_curation.exists():
            old_curation.rename(new_curation)
            curation = json.loads(new_curation.read_text())
            curation["id"] = new_id
            safe_write_json(new_curation, curation)

    return EditResult(ok=True, series_id=new_id or series_id)


# ---- Delete ----


@dataclass
class DeleteResult:
    ok: bool
    title: str | None = None
    curation_removed: bool = False
    error: str | None = None


def delete_series(series_id: str, *, reason: str) -> DeleteResult:
    """Remove a series from series.yaml and its curation file.

    Records the deletion in deleted.yaml. Does NOT check the deletion
    log (the CLI wrapper handles --force-readd).
    """
    yaml_path = paths.series_yaml_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(yaml_path)
        entries = data.get("series") or []
        target = next((e for e in entries if e.get("id") == series_id), None)
        if target is None:
            return DeleteResult(ok=False, error=f"series {series_id!r} not found")

        title = target.get("title", series_id)
        data["series"] = [e for e in entries if e.get("id") != series_id]
        safe_write_yaml(yaml_path, data)

    curation_file = paths.curation_path(series_id)
    curation_removed = False
    if curation_file.exists():
        curation_file.unlink()
        curation_removed = True

    record_deletion(series_id, title, reason)
    return DeleteResult(ok=True, title=title, curation_removed=curation_removed)


# ---- Add ----


@dataclass
class AddResult:
    ok: bool
    series_id: str
    title: str
    error: str | None = None


def add_series_entry(entry: dict[str, Any]) -> AddResult:
    """Append a new series entry to series.yaml.

    The entry dict should contain at least 'id' and 'title'.
    Returns an error if the id already exists.
    """
    sid = entry.get("id", "")
    title = entry.get("title", "")
    if not sid:
        return AddResult(ok=False, series_id="", title=title, error="id is required")

    existing = load_catalog()
    if any(e.id == sid for e in existing):
        return AddResult(
            ok=False,
            series_id=sid,
            title=title,
            error=f"series '{sid}' already exists",
        )

    yaml_path = paths.series_yaml_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(yaml_path)
        data.setdefault("series", []).append(entry)
        safe_write_yaml(yaml_path, data)

    return AddResult(ok=True, series_id=sid, title=title)


def remove_series_from_yaml(series_id: str) -> bool:
    """Remove a series entry from series.yaml by id.

    Returns True if removed, False if not found. Used by merge to
    remove the source series without recording a deletion.
    """
    yaml_path = paths.series_yaml_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(yaml_path)
        entries = data.get("series") or []
        before = len(entries)
        data["series"] = [e for e in entries if e.get("id") != series_id]
        if len(data["series"]) == before:
            return False
        safe_write_yaml(yaml_path, data)

    return True
