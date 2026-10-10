"""Canonical path resolution for the lauschi catalog.

Single source of truth for all file paths used by both the CLI tools
and the web UI. Override the repo root via the LAUSCHI_REPO_ROOT
environment variable for non-standard layouts.
"""

import os
from pathlib import Path

_CATALOG_SUBDIR = Path("assets") / "catalog"


def checkout_root() -> Path:
    """The checkout this code runs from, whatever LAUSCHI_REPO_ROOT says.
    Machine-local files that belong to the working copy, not to the
    catalog data, live here (the Logfire credential)."""
    return Path(__file__).resolve().parent.parent.parent.parent.parent


def repo_root() -> Path:
    env = os.environ.get("LAUSCHI_REPO_ROOT")
    if env:
        return Path(env).resolve()
    return checkout_root()


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


def artist_image_path(series_id: str) -> Path:
    return cover_cache_dir() / f"{series_id}_artist.json"


def cache_dir(provider: str) -> Path:
    return repo_root() / ".cache" / provider


def log_dir() -> Path:
    return repo_root() / "logs" / "catalog"
