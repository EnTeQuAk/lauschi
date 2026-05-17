"""JSON API endpoints for Alpine.js interactions."""

from __future__ import annotations

import json
import re
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter, HTTPException
from filelock import FileLock
from pydantic import BaseModel

from lauschi_catalog.catalog.loader import load_raw
from lauschi_catalog.web.catalog_db import (
    get_all_series,
    get_series_by_id,
    series_exists,
    sync_catalog_to_db,
)
from lauschi_catalog.web.config import CURATION_DIR, SERIES_LOCK, SERIES_YAML
from lauschi_catalog.commands.discover import discover_for_provider
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.web.jobs import create_job
from lauschi_catalog.web.routes.jobs_api import run_subprocess
from lauschi_catalog.web.utils import safe_write_json, safe_write_yaml

router = APIRouter()


@router.post("/sync")
async def post_sync() -> dict[str, int]:
    """Trigger a manual sync of series.yaml -> SQLite."""
    count = sync_catalog_to_db()
    return {"series_synced": count}


class AlbumStatusUpdate(BaseModel):
    include: bool
    exclude_reason: str | None = None


class SeriesEdit(BaseModel):
    title: str | None = None
    id: str | None = None
    aliases: list[str] | None = None
    episode_pattern: str | list[str] | None = None
    content_type: str | None = None


@router.patch("/series/{series_id}/albums/{album_id}")
async def update_album_status(
    series_id: str, album_id: str, update: AlbumStatusUpdate
) -> dict[str, bool]:
    """Toggle include/exclude for a single album in a curation JSON."""
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        raise HTTPException(status_code=404, detail="curation not found")

    data = json.loads(path.read_text())
    albums = data.get("albums", [])
    for album in albums:
        if album.get("album_id") == album_id:
            album["include"] = update.include
            if update.include:
                album.pop("exclude_reason", None)
            elif update.exclude_reason:
                album["exclude_reason"] = update.exclude_reason
            safe_write_json(path, data)
            return {"ok": True}

    raise HTTPException(status_code=404, detail="album not found")


@router.get("/series/{series_id}/edit")
async def get_series_edit(series_id: str) -> dict[str, Any]:
    """Return current series data for the edit form."""
    series = get_series_by_id(series_id)
    if series is None:
        raise HTTPException(status_code=404, detail="series not found")
    return {
        "id": series.id,
        "title": series.title,
        "aliases": series.aliases,
        "episode_pattern": series.episode_pattern,
        "content_type": series.content_type or "hoerspiel",
    }


@router.post("/series/{series_id}/edit")
async def post_series_edit(series_id: str, edit: SeriesEdit) -> dict[str, Any]:
    """Edit series properties in series.yaml."""
    # Validation
    if edit.id is not None:
        if not re.match(r"^[a-z][a-z0-9_]*$", edit.id):
            raise HTTPException(status_code=400, detail="id must be snake_case")
        # Unique check
        existing_ids = [s.id for s in get_all_series() if s.id != series_id]
        if edit.id in existing_ids:
            raise HTTPException(
                status_code=400, detail=f"id '{edit.id}' already exists"
            )

    if edit.episode_pattern is not None:
        patterns = (
            [edit.episode_pattern]
            if isinstance(edit.episode_pattern, str)
            else edit.episode_pattern
        )
        for p in patterns:
            try:
                compiled = re.compile(p)
                if compiled.groups < 1:
                    raise HTTPException(
                        status_code=400,
                        detail=f"pattern {p!r} needs at least 1 capture group",
                    )
            except re.error as e:
                raise HTTPException(
                    status_code=400, detail=f"invalid regex {p!r}: {e}"
                ) from e

    if edit.content_type is not None and edit.content_type not in (
        "hoerspiel",
        "music",
    ):
        raise HTTPException(
            status_code=400, detail="content_type must be 'hoerspiel' or 'music'"
        )

    # Atomic read-modify-write on series.yaml
    with FileLock(str(SERIES_LOCK)):
        data = load_raw(SERIES_YAML)
        raw_entry = None
        for entry in data["series"]:
            if entry.get("id") == series_id:
                raw_entry = entry
                break

        if raw_entry is None:
            raise HTTPException(
                status_code=404, detail="series not found in series.yaml"
            )

        # Apply changes
        if edit.title is not None:
            raw_entry["title"] = edit.title
        if edit.id is not None:
            raw_entry["id"] = edit.id
        if edit.aliases is not None:
            if edit.aliases:
                raw_entry["aliases"] = edit.aliases
            elif "aliases" in raw_entry:
                del raw_entry["aliases"]
        if edit.episode_pattern is not None:
            if edit.episode_pattern:
                raw_entry["episode_pattern"] = edit.episode_pattern
            elif "episode_pattern" in raw_entry:
                del raw_entry["episode_pattern"]
        if edit.content_type is not None:
            if edit.content_type != "hoerspiel":
                raw_entry["content_type"] = edit.content_type
            elif "content_type" in raw_entry:
                del raw_entry["content_type"]

        safe_write_yaml(SERIES_YAML, data)

    # If ID changed, rename curation file
    new_id = edit.id
    if new_id and new_id != series_id:
        old_curation = CURATION_DIR / f"{series_id}.json"
        new_curation = CURATION_DIR / f"{new_id}.json"
        if old_curation.exists():
            old_curation.rename(new_curation)
            # Update id inside the curation JSON
            curation = json.loads(new_curation.read_text())
            curation["id"] = new_id
            safe_write_json(new_curation, curation)

    sync_catalog_to_db()
    return {"ok": True, "id": new_id or series_id}


class SplitAction(BaseModel):
    action: str  # accept | reject


@router.post("/series/{series_id}/split/{split_index}")
async def post_split_action(
    series_id: str, split_index: int, action: SplitAction
) -> dict[str, Any]:
    """Accept or reject a split proposal from AI review.

    Accept: creates a new curation JSON, removes albums from original,
    adds the new series to series.yaml.
    Reject: removes the split proposal from review.splits.
    """
    curation_path = CURATION_DIR / f"{series_id}.json"
    if not curation_path.exists():
        raise HTTPException(status_code=404, detail="curation not found")

    curation = json.loads(curation_path.read_text())
    review = curation.get("review", {})
    splits = review.get("splits", [])
    if split_index < 0 or split_index >= len(splits):
        raise HTTPException(status_code=404, detail="split not found")

    split = splits[split_index]

    if action.action == "reject":
        splits.pop(split_index)
        safe_write_json(curation_path, curation)
        return {"ok": True, "result": "rejected"}

    if action.action == "accept":
        new_id = split.get("new_series_id")
        new_title = split.get("new_series_title")
        album_ids = set(split.get("album_ids", []))

        if not new_id or not new_title or not album_ids:
            raise HTTPException(
                status_code=400, detail="split proposal missing required fields"
            )

        # Check new_id is unique
        if series_exists(new_id):
            raise HTTPException(
                status_code=400, detail=f"series id '{new_id}' already exists"
            )

        new_path = CURATION_DIR / f"{new_id}.json"
        if new_path.exists():
            raise HTTPException(
                status_code=400, detail=f"curation file '{new_id}.json' already exists"
            )

        # Move albums from original to new curation
        albums = curation.get("albums", [])
        moved = [a for a in albums if a.get("album_id") in album_ids]
        remaining = [a for a in albums if a.get("album_id") not in album_ids]

        if not moved:
            raise HTTPException(
                status_code=400, detail="no albums matched split proposal"
            )

        new_curation = {
            "id": new_id,
            "title": new_title,
            "aliases": [],
            "episode_pattern": curation.get("episode_pattern"),
            "provider_artist_ids": curation.get("provider_artist_ids", {}),
            "albums": moved,
            "content_type": curation.get("content_type", "hoerspiel"),
            "split_from": series_id,
            "split_at": datetime.now(UTC).isoformat(),
        }
        new_path = CURATION_DIR / f"{new_id}.json"
        safe_write_json(new_path, new_curation)

        # Update original curation
        curation["albums"] = remaining
        # Remove the accepted split from review.splits
        splits.pop(split_index)
        safe_write_json(curation_path, curation)

        # Add new series to series.yaml (locked)
        with FileLock(str(SERIES_LOCK)):
            data = load_raw(SERIES_YAML)
            data["series"].append(
                {
                    "id": new_id,
                    "title": new_title,
                    "aliases": [],
                    "episode_pattern": curation.get("episode_pattern"),
                    "content_type": curation.get("content_type", "hoerspiel"),
                    "providers": {},
                }
            )
            safe_write_yaml(SERIES_YAML, data)

        sync_catalog_to_db()
        return {"ok": True, "result": "accepted", "new_id": new_id}

    raise HTTPException(status_code=400, detail="action must be 'accept' or 'reject'")


@router.post("/series/{series_id}/discover")
async def discover_series(series_id: str) -> dict[str, str]:
    """Queue a discover job for a series. Discovers artist IDs across providers."""
    job_id = create_job(series_id, "discover")
    run_subprocess(job_id, series_id, "discover")
    return {"job_id": job_id}


class MergeRequest(BaseModel):
    source_id: str
    target_id: str


@router.post("/series/merge")
async def post_merge(request: MergeRequest) -> dict[str, Any]:
    """Merge source series into target.

    Moves all albums from source curation to target curation, copies provider_artist_ids,
    removes source from series.yaml, deletes source curation file.
    """
    if request.source_id == request.target_id:
        raise HTTPException(
            status_code=400, detail="source and target must be different"
        )

    source = get_series_by_id(request.source_id)
    target = get_series_by_id(request.target_id)
    if source is None:
        raise HTTPException(status_code=404, detail="source series not found")
    if target is None:
        raise HTTPException(status_code=404, detail="target series not found")

    source_curation_path = CURATION_DIR / f"{request.source_id}.json"
    target_curation_path = CURATION_DIR / f"{request.target_id}.json"

    if not source_curation_path.exists():
        raise HTTPException(status_code=404, detail="source curation not found")

    source_curation = json.loads(source_curation_path.read_text())
    source_albums = source_curation.get("albums", [])

    if target_curation_path.exists():
        target_curation = json.loads(target_curation_path.read_text())
        target_albums = target_curation.get("albums", [])
    else:
        target_curation = {
            "id": request.target_id,
            "title": target.title,
            "aliases": [],
            "albums": [],
        }
        target_albums = []

    # Build dedup set: episode_num + provider is the key
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
        "provider_artist_ids", {}
    )  # type: ignore[assignment]
    target_providers: dict[str, list[str]] = target_curation.get(
        "provider_artist_ids", {}
    )  # type: ignore[assignment]
    for prov, aids in source_providers.items():
        existing = set(target_providers.get(prov, []))
        existing.update(aids)
        target_providers[prov] = list(existing)
    target_curation["provider_artist_ids"] = target_providers  # type: ignore[reportArgumentType]

    # Write target curation
    safe_write_json(target_curation_path, target_curation)

    # Remove source from series.yaml (locked)
    with FileLock(str(SERIES_LOCK)):
        data: dict[str, Any] = load_raw(SERIES_YAML)  # type: ignore[assignment]
        data["series"] = [s for s in data["series"] if s.get("id") != request.source_id]
        safe_write_yaml(SERIES_YAML, data)

    # Delete source curation file
    source_curation_path.unlink()

    sync_catalog_to_db()
    return {"ok": True, "added": str(added), "skipped": str(skipped)}


class SearchArtistsRequest(BaseModel):
    title: str


def _init_providers() -> list[CatalogProvider]:
    """Initialize available catalog providers, skipping ones missing credentials."""
    providers: list[CatalogProvider] = []
    try:
        from lauschi_catalog.providers.spotify import SpotifyProvider

        providers.append(SpotifyProvider())
    except Exception:
        pass
    try:
        from lauschi_catalog.providers.apple_music import AppleMusicProvider

        providers.append(AppleMusicProvider())
    except Exception:
        pass
    return providers


@router.post("/search-artists")
async def search_artists(request: SearchArtistsRequest) -> dict[str, Any]:
    """Search providers for artist matches by series title.

    Returns found artist name and ID per provider so the caller can
    pre-fill the add-series form before committing.
    """
    providers = _init_providers()
    results: dict[str, Any] = {}
    for p in providers:
        artist = discover_for_provider(p, request.title, verbose=False)
        if artist:
            results[p.name] = {"name": artist.name, "id": artist.id}
    return {"results": results}
