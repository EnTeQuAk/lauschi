"""Small utilities for the web UI."""

from __future__ import annotations

import json
import os
from io import StringIO
from pathlib import Path

from ruamel.yaml import YAML


def safe_write_text(path: Path, text: str) -> None:
    """Write text atomically: temp file + os.replace."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def safe_write_json(path: Path, data: object) -> None:
    """Write JSON atomically with consistent formatting."""
    text = json.dumps(data, indent=2, ensure_ascii=False)
    safe_write_text(path, text + "\n")


_yaml = YAML()
_yaml.preserve_quotes = True  # type: ignore[assignment]
_yaml.width = 200


def safe_write_yaml(path: Path, data: object) -> None:
    """Write YAML atomically via ruamel.yaml, preserving comments."""
    buf = StringIO()
    _yaml.dump(data, buf)
    safe_write_text(path, buf.getvalue())
