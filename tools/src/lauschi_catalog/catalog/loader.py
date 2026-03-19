"""YAML catalog loader and writer.

Uses ruamel.yaml to preserve comments, formatting, and string quoting
when reading and writing series.yaml.
"""

from __future__ import annotations

from pathlib import Path

from ruamel.yaml import YAML

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
SERIES_YAML = REPO_ROOT / "assets" / "catalog" / "series.yaml"

_yaml = YAML()
_yaml.preserve_quotes = True  # type: ignore[assignment]
_yaml.width = 200  # avoid unwanted line wrapping


def load_catalog(path: Path = SERIES_YAML) -> list[CatalogEntry]:
    """Load series.yaml into CatalogEntry models."""
    data = _yaml.load(path)
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

            providers[pname] = ProviderConfig(
                artist_ids=[str(a) for a in aids] if aids else [],
                episode_pattern=pdata.get("episode_pattern"),
            )

        pattern = raw.get("episode_pattern")

        entries.append(
            CatalogEntry(
                id=raw["id"],
                title=raw["title"],
                keywords=raw.get("keywords") or [],
                aliases=raw.get("aliases") or [],
                episode_pattern=pattern,
                cover_url=raw.get("cover_url"),
                providers=providers,
            ),
        )

    return entries


def load_raw(path: Path = SERIES_YAML):
    """Load series.yaml as raw ruamel.yaml data (preserves comments)."""
    return _yaml.load(path)


def save_raw(data, path: Path = SERIES_YAML):
    """Write modified ruamel.yaml data back, preserving comments."""
    with open(path, "w") as f:
        _yaml.dump(data, f)


def update_provider_ids(
    path: Path = SERIES_YAML,
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
