"""Series-level catalog operations.

Pure business logic for editing, deleting, and adding series entries.
No HTTP, no CLI, no console output.
"""

import json
import re
from dataclasses import dataclass
from typing import Any

from filelock import FileLock

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.deleted import record_deletion
from lauschi_catalog.catalog.io import load_raw, safe_write_json, write_catalog
from lauschi_catalog.catalog.loader import load_catalog

# Series ids are stable snake_case ASCII. They may start with a digit
# (e.g. "5_geschwister", "100_wolf").
SERIES_ID_PATTERN = r"[a-z0-9][a-z0-9_]*"
SERIES_ID_RE = re.compile(rf"^{SERIES_ID_PATTERN}$")


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
        if not SERIES_ID_RE.match(changes.id):
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
        "audiobook",
    ):
        errors.append("content_type must be 'hoerspiel', 'music' or 'audiobook'")

    return errors


def edit_series(series_id: str, changes: SeriesChanges) -> EditResult:
    """Edit a series in series.json. Returns the (possibly new) series id."""
    errors = validate_series_changes(series_id, changes)
    if errors:
        return EditResult(ok=False, series_id=series_id, error="; ".join(errors))

    catalog_file = paths.catalog_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(catalog_file)
        raw_entry = None
        for entry in data["series"]:
            if entry.get("id") == series_id:
                raw_entry = entry
                break

        if raw_entry is None:
            return EditResult(
                ok=False,
                series_id=series_id,
                error="series not found in series.json",
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

        write_catalog(catalog_file, data)

    new_id = changes.id
    if new_id and new_id != series_id:
        old_curation = paths.curation_path(series_id)
        if old_curation.exists():
            old_curation.rename(paths.curation_path(new_id))

    # apply writes the pattern and the content type from the curation into
    # series.json and refuses a curation whose id is not its file's, so the
    # curation has to hold what was edited here.
    edited: dict[str, str | list[str] | None] = {}
    if new_id is not None:
        edited["id"] = new_id
    if changes.episode_pattern is not None:
        edited["episode_pattern"] = changes.episode_pattern or None
    if changes.content_type is not None:
        edited["content_type"] = changes.content_type
    curation_path = paths.curation_path(new_id or series_id)
    if edited and curation_path.exists():
        curation = json.loads(curation_path.read_text())
        curation.update(edited)
        safe_write_json(curation_path, curation)

    return EditResult(ok=True, series_id=new_id or series_id)


# ---- Delete ----


@dataclass
class DeleteResult:
    ok: bool
    title: str | None = None
    curation_removed: bool = False
    error: str | None = None


def delete_series(series_id: str, *, reason: str) -> DeleteResult:
    """Remove a series from series.json and its curation file.

    Records the deletion in deleted.json. Does NOT check the deletion
    log (the CLI wrapper handles --force-readd).
    """
    catalog_file = paths.catalog_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(catalog_file)
        entries = data.get("series") or []
        target = next((e for e in entries if e.get("id") == series_id), None)
        if target is None:
            return DeleteResult(ok=False, error=f"series {series_id!r} not found")

        title = target.get("title", series_id)
        data["series"] = [e for e in entries if e.get("id") != series_id]
        write_catalog(catalog_file, data)

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
    """Append a new series entry to series.json.

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

    catalog_file = paths.catalog_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(catalog_file)
        data.setdefault("series", []).append(entry)
        write_catalog(catalog_file, data)

    return AddResult(ok=True, series_id=sid, title=title)


def remove_series_entry(series_id: str) -> bool:
    """Remove a series entry from series.json by id.

    Returns True if removed, False if not found. Used by merge to
    remove the source series without recording a deletion.
    """
    catalog_file = paths.catalog_path()
    lock = paths.series_lock_path()

    with FileLock(str(lock)):
        data = load_raw(catalog_file)
        entries = data.get("series") or []
        before = len(entries)
        data["series"] = [e for e in entries if e.get("id") != series_id]
        if len(data["series"]) == before:
            return False
        write_catalog(catalog_file, data)

    return True
