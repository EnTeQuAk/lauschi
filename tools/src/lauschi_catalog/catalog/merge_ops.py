"""Merge and split operations for catalog series.

Pure business logic, no HTTP or CLI concerns.
"""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.curate_ops import album_provenance
from lauschi_catalog.catalog.episode_range import title_number
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.partition import family_of
from lauschi_catalog.catalog.series_ops import add_series_entry, remove_series_from_yaml


@dataclass
class MergeResult:
    ok: bool
    added: int = 0
    skipped: int = 0
    error: str | None = None


def merge_series(
    source_id: str,
    target_id: str,
    *,
    target_title: str | None = None,
) -> MergeResult:
    """Merge source series into target.

    Moves all albums from source curation to target, copies
    provider_artist_ids, removes source from series.yaml, deletes
    source curation file.

    Args:
        target_title: Used when the target curation file doesn't exist
            yet and we need to create a stub.
    """
    if source_id == target_id:
        return MergeResult(ok=False, error="source and target must be different")

    source_path = paths.curation_path(source_id)
    target_path = paths.curation_path(target_id)

    if not source_path.exists():
        return MergeResult(ok=False, error="source curation not found")

    source_curation = json.loads(source_path.read_text())
    source_albums: list[dict[str, Any]] = source_curation.get("albums", [])

    if target_path.exists():
        target_curation = json.loads(target_path.read_text())
        target_albums: list[dict[str, Any]] = target_curation.get("albums", [])
    else:
        target_curation: dict[str, Any] = {
            "id": target_id,
            "title": target_title or target_id,
            "aliases": [],
            "albums": [],
        }
        target_albums = []

    existing_keys = {
        (a.get("episode_num"), a.get("provider"), a.get("album_id"))
        for a in target_albums
    }
    added = 0
    skipped = 0
    for a in source_albums:
        key = (a.get("episode_num"), a.get("provider"), a.get("album_id"))
        if key in existing_keys:
            skipped += 1
            continue
        target_albums.append(a)
        existing_keys.add(key)
        added += 1

    target_curation["albums"] = target_albums

    # Merge provider_artist_ids
    source_providers: dict[str, list[str]] = source_curation.get(
        "provider_artist_ids",
        {},
    )
    target_providers: dict[str, list[str]] = target_curation.get(
        "provider_artist_ids",
        {},
    )
    for prov, aids in source_providers.items():
        existing = set(target_providers.get(prov, []))
        existing.update(aids)
        target_providers[prov] = list(existing)
    target_curation["provider_artist_ids"] = target_providers

    safe_write_json(target_path, target_curation)
    remove_series_from_yaml(source_id)
    source_path.unlink()

    return MergeResult(ok=True, added=added, skipped=skipped)


# ---- Moving albums inside a family ----


@dataclass
class MoveResult:
    ok: bool
    moved: int = 0
    error: str | None = None


def move_albums(
    source_id: str, target_id: str, albums: list[tuple[str, str]]
) -> MoveResult:
    """Hand albums from one entry of a family to another.

    ``albums`` are (provider, album_id) pairs. In the source curation the
    album becomes sub_series_bleed and names the target as its owner, the
    note a curate run reads. In the target curation it is included, with
    the number the target's own pattern reads from the title: a number is
    a fact of the line, so the source's is not carried over. Both rows are
    stamped as an operator's decision. Nothing is written unless every
    album can be moved, and series.yaml changes only with the next apply.
    """
    if source_id == target_id:
        return MoveResult(ok=False, error="source and target must be different")
    catalog = load_catalog()
    entries = {e.id: e for e in catalog}
    for series_id in (source_id, target_id):
        if series_id not in entries:
            return MoveResult(ok=False, error=f"'{series_id}' is not in the catalog")
    target = entries[target_id]
    if source_id not in {m.id for m in family_of(target, catalog).members}:
        return MoveResult(
            ok=False, error=f"'{source_id}' and '{target_id}' are not in one family"
        )

    curations: dict[str, dict[str, Any]] = {}
    for series_id in (source_id, target_id):
        path = paths.curation_path(series_id)
        if not path.exists():
            return MoveResult(ok=False, error=f"'{series_id}' has no curation")
        curations[series_id] = json.loads(path.read_text())
    rows = {
        series_id: {(a.get("provider"), a.get("album_id")): a for a in cur["albums"]}
        for series_id, cur in curations.items()
    }
    for key in albums:
        if key not in rows[source_id] and key not in rows[target_id]:
            return MoveResult(
                ok=False, error=f"{key[0]}:{key[1]} is in neither curation"
            )

    for key in albums:
        provider, album_id = key
        known = rows[source_id].get(key) or rows[target_id][key]
        identity = {
            "album_id": album_id,
            "provider": provider,
            "title": known.get("title", ""),
            "release_date": known.get("release_date"),
        }
        taken = rows[target_id].get(key)
        if taken is None:
            taken = dict(identity)
            curations[target_id]["albums"].append(taken)
        taken.pop("exclude_reason", None)
        taken.update(
            include=True,
            episode_num=title_number(
                target.effective_pattern(provider), taken["title"]
            ),
            confidence="high",
            notes=f"Moved here from '{source_id}' by hand.",
            **album_provenance("operator"),
        )
        given = rows[source_id].get(key)
        if given is None:
            given = dict(identity)
            curations[source_id]["albums"].append(given)
        given.update(
            include=False,
            exclude_reason="sub_series_bleed",
            episode_num=None,
            confidence="high",
            notes=f"Belongs to '{target_id}'",
            **album_provenance("operator"),
        )

    for series_id, curation in curations.items():
        safe_write_json(paths.curation_path(series_id), curation)
    return MoveResult(ok=True, moved=len(albums))


# ---- Split operations ----


@dataclass
class SplitResult:
    ok: bool
    action: str = ""
    new_id: str | None = None
    error: str | None = None


def _get_sub_series(curation: dict) -> list[dict]:
    """Get the sub_series list from series_facts."""
    return curation.get("series_facts", {}).get("sub_series", [])


_KNOWN_PROVIDERS = frozenset(("spotify", "apple_music"))


def normalize_album_ids(
    raw_ids: list[str],
    album_id_set: set[str] | None = None,
) -> set[str]:
    """Normalize sub_series album_ids to bare IDs.

    Strips ``provider:`` prefixes that older AI outputs sometimes added.
    When *album_id_set* is provided, unresolvable IDs are dropped silently.
    """
    result: set[str] = set()
    for raw in raw_ids:
        if ":" in raw:
            provider, bare = raw.split(":", 1)
            if provider in _KNOWN_PROVIDERS:
                raw = bare
        if album_id_set is None or raw in album_id_set:
            result.add(raw)
    return result


def reject_split(series_id: str, split_index: int) -> SplitResult:
    """Remove a sub_series proposal from series_facts."""
    cur_path = paths.curation_path(series_id)
    if not cur_path.exists():
        return SplitResult(ok=False, error="curation not found")

    curation = json.loads(cur_path.read_text())
    subs = _get_sub_series(curation)
    if split_index < 0 or split_index >= len(subs):
        return SplitResult(ok=False, error="split not found")

    subs.pop(split_index)
    safe_write_json(cur_path, curation)
    return SplitResult(ok=True, action="rejected")


def accept_split(
    series_id: str,
    split_index: int,
    *,
    new_id: str | None = None,
    new_title: str | None = None,
) -> SplitResult:
    """Accept a split: create new curation, move albums, add to series.yaml."""
    cur_path = paths.curation_path(series_id)
    if not cur_path.exists():
        return SplitResult(ok=False, error="curation not found")

    curation = json.loads(cur_path.read_text())
    subs = _get_sub_series(curation)
    if split_index < 0 or split_index >= len(subs):
        return SplitResult(ok=False, error="split not found")

    sub = subs[split_index]
    label = sub.get("label", "")
    parent_title = curation.get("title", series_id)
    if not new_id:
        new_id = f"{series_id}_{label}"
    if not new_title:
        new_title = f"{parent_title}: {label.replace('_', ' ').title()}"
    albums = curation.get("albums", [])
    all_album_ids = {a.get("album_id", "") for a in albums}
    album_ids = normalize_album_ids(sub.get("album_ids", []), all_album_ids)

    if not label or not album_ids:
        return SplitResult(ok=False, error="sub_series missing label or album_ids")

    existing = load_catalog()
    if any(e.id == new_id for e in existing):
        return SplitResult(ok=False, error=f"series id '{new_id}' already exists")

    new_path = paths.curation_path(new_id)
    if new_path.exists():
        return SplitResult(
            ok=False,
            error=f"curation file '{new_id}.json' already exists",
        )

    line = [a for a in albums if a.get("album_id", "") in album_ids]
    remaining = [a for a in albums if a.get("album_id", "") not in album_ids]

    if not line:
        return SplitResult(ok=False, error="no albums matched sub_series")

    # The parent excluded some of the line as sub_series_bleed precisely
    # because they belong to it; in the child they are its own albums, so
    # they arrive undecided and the child's run decides them.
    moved = [
        a
        for a in line
        if a.get("include", True) or a.get("exclude_reason") != "sub_series_bleed"
    ]

    now = datetime.now(UTC).isoformat()

    new_curation = {
        "id": new_id,
        "title": new_title,
        "aliases": [],
        "episode_pattern": None,
        "provider_artist_ids": curation.get("provider_artist_ids", {}),
        "age_note": curation.get("age_note", ""),
        "curator_notes": (
            f"Split from {parent_title}. "
            f"Contains {len(line)} albums from the '{label}' sub-series."
        ),
        "series_facts": {},
        "albums": moved,
        "content_type": curation.get("content_type", "hoerspiel"),
        "incomplete": False,
        "incomplete_reason": "",
        "split_from": series_id,
        "split_at": now,
        "curated_at": now,
    }
    safe_write_json(new_path, new_curation)

    # Inherit cover URLs for the moved albums from the parent's cache;
    # the split flow never re-discovers, so nothing else would write them.
    parent_covers_path = paths.cover_cache_path(series_id)
    if parent_covers_path.exists():
        parent_covers = json.loads(parent_covers_path.read_text())
        moved_ids = {a.get("album_id") for a in line}
        inherited = {k: v for k, v in parent_covers.items() if k in moved_ids}
        if inherited:
            safe_write_json(paths.cover_cache_path(new_id), inherited)

    curation["albums"] = remaining
    subs.pop(split_index)
    safe_write_json(cur_path, curation)

    providers: dict = {}
    for prov, aids in curation.get("provider_artist_ids", {}).items():
        providers[prov] = {"artist_ids": list(aids)}

    add_series_entry(
        {
            "id": new_id,
            "title": new_title,
            "aliases": [],
            "episode_pattern": None,
            "content_type": curation.get("content_type", "hoerspiel"),
            "split_from": series_id,
            "providers": providers,
        }
    )

    return SplitResult(ok=True, action="accepted", new_id=new_id)
