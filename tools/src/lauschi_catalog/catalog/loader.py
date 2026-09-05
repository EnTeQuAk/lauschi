"""YAML catalog loader and writer.

Uses ruamel.yaml to preserve comments, formatting, and string quoting
when reading and writing series.yaml.
"""

from pathlib import Path

from lauschi_catalog.catalog import io
from lauschi_catalog.catalog.io import locked_raw
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.paths import series_yaml_path


def _series_path(path: Path | None) -> Path:
    """Call-time resolution so LAUSCHI_REPO_ROOT overrides always work."""
    return path if path is not None else series_yaml_path()


def _series_path(path: Path | None) -> Path:
    """Call-time resolution so LAUSCHI_REPO_ROOT overrides always work."""
    return path if path is not None else series_yaml_path()


def _cache_key(path: Path) -> tuple[str, int, int]:
    """Cheap identity of the file's content.

    size + mtime_ns catches every write, including a same-size one: one
    key per content version, which is the semantics the CLI wants.
    """
    st = path.stat()
    return (str(path), st.st_size, st.st_mtime_ns)


#: Per-process parse cache: {cache key: parsed entries}.
_catalog_cache: dict[tuple[str, int, int], list[CatalogEntry]] = {}


def clear_catalog_cache() -> None:
    """Forget cached parses (exported mostly for test isolation)."""
    _catalog_cache.clear()


def _parse_catalog(path: Path) -> list[CatalogEntry]:
    """The expensive yaml round trip: 1.6 MB file, 3.5 s measured."""
    data = io.yaml_instance().load(path)
    entries = []

    for raw in data["series"]:
        providers: dict[str, ProviderConfig] = {}
        raw_providers = raw.get("providers", {}) or {}

        for pname, pdata in raw_providers.items():
            if pdata is None:
                continue
            aids = pdata.get("artist_ids", [])

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


def load_catalog(path: Path | None = None) -> list[CatalogEntry]:
    """Load series.yaml into CatalogEntry models.

    Parsed once per file version and deep-copied per call: one mutation
    of a returned entry must never leak into anyone else's view, and a
    copy is still far cheaper than re-parsing the file.
    """
    import copy

    target = _series_path(path)
    if not target.exists():
        return []
    key = _cache_key(target)
    if key not in _catalog_cache:
        _catalog_cache[key] = _parse_catalog(target)
    return copy.deepcopy(_catalog_cache[key])


def load_raw(path: Path | None = None):
    """Load series.yaml as raw ruamel.yaml data (preserves comments)."""
    return io.load_raw(_series_path(path))


def save_raw(data: object, path: Path | None = None) -> None:
    """Write modified ruamel.yaml data back, preserving comments.

    Uses atomic write (temp file + os.replace) with file locking
    via catalog.io.
    """
    io.save_raw(data, _series_path(path))


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
    count = 0
    with locked_raw(path) as data:
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
            # still inside locked_raw's window; plain atomic write
            io.safe_write_yaml(series_yaml_path(), data)

    return count


def lookup_catalog_entry(query: str) -> CatalogEntry | None:
    """Resolve ``query`` (id or exact title) to its catalog entry.

    Raises if the catalog cannot be loaded so a broken ``series.yaml``
    does not silently look like a new series.
    """
    entries = load_catalog()
    for entry in entries:
        if entry.id == query:
            return entry
    for entry in entries:
        if entry.title == query:
            return entry
    return None
