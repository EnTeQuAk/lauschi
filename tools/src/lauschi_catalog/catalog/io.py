"""Atomic file I/O with file locking for the catalog.

All writes use temp-file + os.replace for atomicity. Edits of
series.json happen inside `locked_raw`, which holds a FileLock on the
series lock file so CLI and web processes do not drop each other's edits. The catalog files (series.json,
deleted.json, reference_map.json) are JSON in the layout of
`dump_catalog`.
"""

import json
import os
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from filelock import FileLock

from lauschi_catalog.catalog import paths


def safe_write_text(path: Path, text: str) -> None:
    """Write text atomically: temp file + os.replace."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def safe_write_json(path: Path, data: object) -> None:
    """Write JSON atomically with consistent formatting."""
    text = json.dumps(data, indent=2, ensure_ascii=False)
    safe_write_text(path, text + "\n")


def _one_line(value: object) -> bool:
    """A plain value, or a dict or list of plain values only."""
    if isinstance(value, dict):
        return not any(isinstance(item, (dict, list)) for item in value.values())
    if isinstance(value, list):
        return not any(isinstance(item, (dict, list)) for item in value)
    return True


def _dump(value: object, depth: int) -> str:
    if _one_line(value):
        return json.dumps(value, ensure_ascii=False)
    pad, inner = "  " * depth, "  " * (depth + 1)
    if isinstance(value, dict):
        body = ",\n".join(
            f"{inner}{json.dumps(key, ensure_ascii=False)}: {_dump(item, depth + 1)}"
            for key, item in value.items()
        )
        return "{\n" + body + "\n" + pad + "}"
    assert isinstance(value, list)
    body = ",\n".join(f"{inner}{_dump(item, depth + 1)}" for item in value)
    return "[\n" + body + "\n" + pad + "]"


def dump_catalog(data: object) -> str:
    """The catalog as JSON a diff can be read in: indented by two spaces,
    with every dict or list of plain values (an album, a list of aliases)
    on one line, so a changed album is a one-line diff."""
    return _dump(data, 0) + "\n"


def write_catalog(path: Path, data: object) -> None:
    """Write a catalog file (series.json, deleted.json) atomically in the
    layout of `dump_catalog`."""
    safe_write_text(path, dump_catalog(data))


def load_raw(path: Path | None = None) -> dict:
    """A catalog file as plain data: series.json, or the one at ``path``."""
    target = path if path is not None else paths.catalog_path()
    return json.loads(target.read_text(encoding="utf-8"))


def save_catalog(data: dict) -> None:
    """Write series.json from inside a `locked_raw` window."""
    write_catalog(paths.catalog_path(), data)


@contextmanager
def locked_raw() -> Iterator[dict]:
    """series.json under the write lock, for load -> change -> write spans.

    Write it with `save_catalog` before the window closes. A read, change
    and write outside one window can drop a concurrent web edit.
    """
    lock = paths.series_lock_path()
    with FileLock(str(lock)):
        yield load_raw()


def find_series(data: dict, series_id: str) -> dict | None:
    """The entry with ``series_id`` in raw catalog data, or None."""
    return next((e for e in data.get("series", []) if e.get("id") == series_id), None)


def load_curation(series_id: str) -> dict:
    """One curation JSON, parsed once, through one path.

    Replaces the hand-rolled ``json.loads(path.read_text())`` sites; a
    broken file raises here so every caller sees the same failure.
    """
    return json.loads(paths.curation_path(series_id).read_text(encoding="utf-8"))


def iter_curations() -> Iterator[tuple[str, dict]]:
    """(series_id, parsed curation) for every curation file, sorted.

    The single enumeration for the audit selector, apply --all, lint
    --all, the report, and the web dashboard.
    """
    d = paths.curation_dir()
    if not d.exists():
        return iter(())
    return iter(
        (p.stem, json.loads(path.read_text(encoding="utf-8")))
        for path in sorted(d.glob("*.json"))
        for p in [path]
    )
