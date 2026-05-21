"""Atomic file I/O with file locking for the catalog.

All writes use temp-file + os.replace for atomicity. YAML writes
acquire a FileLock on the series lock file to prevent concurrent
writes from CLI and web processes.
"""

from __future__ import annotations

import json
import os
from io import StringIO
from pathlib import Path

from filelock import FileLock
from ruamel.yaml import YAML

from lauschi_catalog.catalog import paths

_yaml = YAML()
_yaml.preserve_quotes = True  # type: ignore[assignment]
_yaml.width = 200


def safe_write_text(path: Path, text: str) -> None:
    """Write text atomically: temp file + os.replace."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def safe_write_json(path: Path, data: object) -> None:
    """Write JSON atomically with consistent formatting."""
    text = json.dumps(data, indent=2, ensure_ascii=False)
    safe_write_text(path, text + "\n")


def safe_write_yaml(path: Path, data: object) -> None:
    """Write YAML atomically via ruamel.yaml, preserving comments."""
    buf = StringIO()
    _yaml.dump(data, buf)
    safe_write_text(path, buf.getvalue())


def load_raw(path: Path | None = None):
    """Load series.yaml as raw ruamel.yaml data (preserves comments)."""
    target = path if path is not None else paths.series_yaml_path()
    return _yaml.load(target)


def save_raw(data: object, path: Path | None = None) -> None:
    """Write series.yaml atomically with file lock."""
    target = path if path is not None else paths.series_yaml_path()
    lock = paths.series_lock_path()
    with FileLock(str(lock)):
        safe_write_yaml(target, data)
