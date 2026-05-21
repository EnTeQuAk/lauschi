"""Canonical path resolution for the lauschi catalog.

Single source of truth for all file paths used by both the CLI tools
and the web UI. Override the repo root via the LAUSCHI_REPO_ROOT
environment variable for non-standard layouts.
"""

from __future__ import annotations

import os
from pathlib import Path

_CATALOG_SUBDIR = Path("assets") / "catalog"


def repo_root() -> Path:
    env = os.environ.get("LAUSCHI_REPO_ROOT")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parent.parent.parent.parent.parent


def series_yaml_path() -> Path:
    return repo_root() / _CATALOG_SUBDIR / "series.yaml"


def curation_dir() -> Path:
    return repo_root() / _CATALOG_SUBDIR / "curation"


def curation_path(series_id: str) -> Path:
    return curation_dir() / f"{series_id}.json"


def series_lock_path() -> Path:
    return repo_root() / _CATALOG_SUBDIR / ".series.yaml.lock"


def deleted_yaml_path() -> Path:
    return repo_root() / _CATALOG_SUBDIR / "deleted.yaml"


def cover_cache_dir() -> Path:
    return repo_root() / _CATALOG_SUBDIR / ".covers"


def cover_cache_path(series_id: str) -> Path:
    return cover_cache_dir() / f"{series_id}.json"


def cache_dir(provider: str) -> Path:
    return repo_root() / ".cache" / provider


def log_dir() -> Path:
    return repo_root() / "logs" / "catalog"


# Backward-compatible module-level constants.
# These exist so that existing code and tests that monkeypatch
# e.g. ``loader.SERIES_YAML`` or ``config.CURATION_DIR`` keep
# working during the migration. New code should call the functions.
REPO_ROOT = repo_root()
SERIES_YAML = series_yaml_path()
CURATION_DIR = curation_dir()
SERIES_LOCK = series_lock_path()
