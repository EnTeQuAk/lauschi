"""YAML catalog loader and writer.

Uses ruamel.yaml to preserve comments, formatting, and string quoting
when reading and writing series.yaml.
"""

from __future__ import annotations

from pathlib import Path

from ruamel.yaml import YAML

from lauschi_catalog.catalog.io import save_raw as _save_raw
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.paths import (
    REPO_ROOT,  # noqa: F401 — re-exported for existing callers
    SERIES_YAML,  # noqa: F401 — re-exported for existing callers
)

_yaml = YAML()
_yaml.preserve_quotes = True  # type: ignore[assignment]
_yaml.width = 200  # avoid unwanted line wrapping


def _series_path(path: Path | None) -> Path:
    # Module-level SERIES_YAML is resolved at call time so tests can
    # monkeypatch ``loader.SERIES_YAML`` without binding stale defaults.
    return path if path is not None else SERIES_YAML


def load_catalog(path: Path | None = None) -> list[CatalogEntry]:
    """Load series.yaml into CatalogEntry models."""
    data = _yaml.load(_series_path(path))
    entries = []

    for raw in data["series"]:
        providers: dict[str, ProviderConfig] = {}
        raw_providers = raw.get("providers", {}) or {}

        for pname, pdata in raw_providers.items():
            if pdata is None:
                continue
            # Artist IDs can be under 'artist_ids' (list) or 'artist_id' (single)
            aids = pdata.get("artist_ids", [])
            if not aids:
                single = pdata.get("artist_id")
                if single:
                    aids = [str(single)]

            albums_raw = pdata.get("albums") or []
            providers[pname] = ProviderConfig(
                artist_ids=[str(a) for a in aids] if aids else [],
                album_ids=[str(a["id"]) for a in albums_raw if a.get("id")],
                episode_pattern=pdata.get("episode_pattern"),
                has_albums=bool(albums_raw),
            )

        series_facts = raw.get("series_facts")

        pattern = raw.get("episode_pattern")

        entries.append(
            CatalogEntry(
                id=raw["id"],
                title=raw["title"],
                aliases=raw.get("aliases") or [],
                episode_pattern=pattern,
                cover_url=raw.get("cover_url"),
                content_type=raw.get("content_type"),
                series_facts=series_facts,
                split_from=raw.get("split_from"),
                providers=providers,
            ),
        )

    return entries


def load_raw(path: Path | None = None):
    """Load series.yaml as raw ruamel.yaml data (preserves comments)."""
    return _yaml.load(_series_path(path))


def save_raw(data: object, path: Path | None = None) -> None:
    """Write modified ruamel.yaml data back, preserving comments.

    Uses atomic write (temp file + os.replace) with file locking
    via catalog.io.
    """
    _save_raw(data, path)


def update_provider_ids(
    path: Path | None = None,
    *,
    updates: dict[str, dict[str, list[str]]],
) -> int:
    """Update provider artist_ids in series.yaml.

    Args:
        updates: {series_id: {provider_name: [artist_ids]}}

    Returns number of series updated.
    """
    data = load_raw(path)
    count = 0

    for raw in data["series"]:
        sid = raw["id"]
        if sid not in updates:
            continue

        if "providers" not in raw:
            raw["providers"] = {}

        for pname, aids in updates[sid].items():
            if pname not in raw["providers"]:
                raw["providers"][pname] = {}
            raw["providers"][pname]["artist_ids"] = aids
            count += 1

    if count > 0:
        save_raw(data, path)

    return count
