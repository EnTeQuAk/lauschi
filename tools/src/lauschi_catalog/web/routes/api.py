"""JSON API endpoints for Alpine.js interactions."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from lauschi_catalog.catalog.album_ops import update_album as _update_album
from lauschi_catalog.catalog.discover_ops import (
    discover_candidates,
    discover_for_provider,
    discover_one,
    match_artist,
)
from lauschi_catalog.catalog.loader import update_provider_ids
from lauschi_catalog.catalog.merge_ops import accept_split, merge_series, reject_split
from lauschi_catalog.catalog.providers_init import init_providers
from lauschi_catalog.catalog.series_ops import SeriesChanges, edit_series
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.web.catalog_store import get_series_by_id, reload_catalog
from lauschi_catalog.web.jobs import create_job, list_jobs
from lauschi_catalog.web.pipeline import next_action, pipeline_status
from lauschi_catalog.web.routes.jobs_api import launch_in_process

router = APIRouter()


@router.post("/sync")
async def post_sync() -> dict[str, int]:
    """Trigger a manual reload of series.yaml into the catalog store."""
    count = reload_catalog()
    return {"series_synced": count}


_cover_providers: dict[str, CatalogProvider | None] = {}


def _cover_provider(name: str) -> CatalogProvider | None:
    """Lazily construct one provider instance per process for cover lookups."""
    if name not in _cover_providers:
        result = init_providers(name)
        _cover_providers[name] = result.providers[0] if result.providers else None
    return _cover_providers[name]


@router.get("/cover/{provider}/{album_id}")
async def album_cover(provider: str, album_id: str) -> RedirectResponse:
    """Redirect to the album's CDN cover image, resolving on demand.

    album_details is disk-cached in the provider layer, so each album
    hits the provider API at most once per cache TTL; the browser then
    caches the CDN image itself.
    """
    if provider not in ("spotify", "apple_music"):
        raise HTTPException(status_code=404, detail="unknown provider")
    p = _cover_provider(provider)
    if p is None:
        raise HTTPException(status_code=404, detail="provider unavailable")
    detail = p.album_details(album_id)
    if detail is None or not detail.image_url:
        raise HTTPException(status_code=404, detail="no cover")
    return RedirectResponse(
        url=detail.image_url,
        status_code=302,
        headers={"Cache-Control": "public, max-age=86400"},
    )


class AlbumStatusUpdate(BaseModel):
    include: bool | None = None
    exclude_reason: str | None = None
    episode_num: int | str | None = None
    title: str | None = None


class SeriesEdit(BaseModel):
    title: str | None = None
    id: str | None = None
    aliases: list[str] | None = None
    episode_pattern: str | list[str] | None = None
    content_type: str | None = None


@router.patch("/series/{series_id}/albums/{album_id}")
async def update_album(
    series_id: str, album_id: str, update: AlbumStatusUpdate
) -> dict[str, bool]:
    """Update fields on a single album in a curation JSON."""
    sent = update.model_fields_set
    kwargs: dict[str, Any] = {}
    if "include" in sent:
        kwargs["include"] = update.include
    if "exclude_reason" in sent:
        kwargs["exclude_reason"] = update.exclude_reason
    if "episode_num" in sent:
        kwargs["episode_num"] = update.episode_num
    if "title" in sent:
        kwargs["title"] = update.title

    result = _update_album(series_id, album_id, **kwargs)
    if not result.ok:
        raise HTTPException(status_code=404, detail=result.error or "unknown error")
    return {"ok": True}


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
    changes = SeriesChanges(
        title=edit.title,
        id=edit.id,
        aliases=edit.aliases,
        episode_pattern=edit.episode_pattern,
        content_type=edit.content_type,
    )
    result = edit_series(series_id, changes)
    if not result.ok:
        status = 404 if "not found" in (result.error or "") else 400
        raise HTTPException(status_code=status, detail=result.error)

    reload_catalog()
    return {"ok": True, "id": result.series_id}


class SplitAction(BaseModel):
    action: str  # accept | reject
    new_id: str | None = None
    new_title: str | None = None


@router.post("/series/{series_id}/split/{split_index}")
async def post_split_action(
    series_id: str, split_index: int, action: SplitAction
) -> dict[str, Any]:
    """Accept or reject a sub_series split proposal."""
    if action.action == "reject":
        result = reject_split(series_id, split_index)
    elif action.action == "accept":
        result = accept_split(
            series_id,
            split_index,
            new_id=action.new_id,
            new_title=action.new_title,
        )
    else:
        raise HTTPException(
            status_code=400, detail="action must be 'accept' or 'reject'"
        )

    if not result.ok:
        status = 404 if "not found" in (result.error or "") else 400
        raise HTTPException(status_code=status, detail=result.error)

    reload_catalog()
    resp: dict[str, Any] = {"ok": True, "result": result.action}
    if result.new_id:
        resp["new_id"] = result.new_id
    return resp


@router.post("/series/{series_id}/discover")
async def discover_series(series_id: str) -> dict[str, str]:
    """Queue a discover job for a series. Runs in-process via library."""
    series = get_series_by_id(series_id)
    if series is None:
        raise HTTPException(status_code=404, detail="series not found")

    providers = _init_providers()
    job_id = create_job(series_id, "discover")
    launch_in_process(
        job_id,
        discover_one,
        series.title,
        providers,
        write=True,
    )
    return {"job_id": job_id}


class AcceptArtistRequest(BaseModel):
    provider: str
    artist_id: str


@router.post("/series/{series_id}/accept-artist")
async def accept_artist(series_id: str, request: AcceptArtistRequest) -> dict[str, Any]:
    """Write a discovered artist ID to series.yaml for a specific provider.

    Merges with existing artist_ids so accepting a new ID doesn't
    overwrite previously accepted ones.
    """
    series = get_series_by_id(series_id)
    if series is None:
        raise HTTPException(status_code=404, detail="series not found")

    existing = series.artist_ids(request.provider)
    merged = list(existing)
    if request.artist_id not in merged:
        merged.append(request.artist_id)

    count = update_provider_ids(updates={series_id: {request.provider: merged}})
    if count == 0:
        raise HTTPException(status_code=400, detail="no series updated")

    reload_catalog()
    return {"ok": True, "series_id": series_id, "provider": request.provider}


class MergeRequest(BaseModel):
    source_id: str
    target_id: str


@router.post("/series/merge")
async def post_merge(request: MergeRequest) -> dict[str, Any]:
    """Merge source series into target."""
    target = get_series_by_id(request.target_id)
    result = merge_series(
        request.source_id,
        request.target_id,
        target_title=target.title if target else None,
    )
    if not result.ok:
        status = 404 if "not found" in (result.error or "") else 400
        raise HTTPException(status_code=status, detail=result.error)

    reload_catalog()
    return {"ok": True, "added": str(result.added), "skipped": str(result.skipped)}


class SearchArtistsRequest(BaseModel):
    title: str


def _init_providers() -> list[CatalogProvider]:
    """Initialize available catalog providers, skipping ones missing credentials."""
    return init_providers().providers


@router.post("/search-artists")
async def search_artists(request: SearchArtistsRequest) -> dict[str, Any]:
    """Search providers for artist matches by series title.

    Returns found artist name and ID per provider so the caller can
    pre-fill the add-series form before committing.
    """
    providers = _init_providers()
    results: dict[str, Any] = {}
    for p in providers:
        artist = discover_for_provider(p, request.title)
        if artist:
            results[p.name] = {"name": artist.name, "id": artist.id}
    return {"results": results}


@router.post("/series/{series_id}/discover-preview")
async def discover_preview(series_id: str) -> dict[str, Any]:
    """Return structured discover candidates per provider (no side effects)."""
    series = get_series_by_id(series_id)
    if series is None:
        raise HTTPException(status_code=404, detail="series not found")

    providers = _init_providers()
    results: dict[str, list[dict[str, Any]]] = {}
    best_match: dict[str, dict[str, Any] | None] = {}

    for p in providers:
        candidates = discover_candidates(p, series.title)
        results[p.name] = [
            {
                "id": artist.id,
                "name": artist.name,
                "provider": artist.provider,
                "genres": artist.genres,
                "followers": artist.followers,
                "confidence": confidence,
            }
            for artist, confidence in candidates
        ]
        matched = match_artist(series.title, [a for a, _ in candidates])
        best_match[p.name] = (
            {"id": matched.id, "name": matched.name} if matched else None
        )

    return {"candidates": results, "best_match": best_match}


_STAGE_COMMANDS = ["discover", "curate", "audit", "apply", "validate"]


@router.get("/series/{series_id}/pipeline")
async def get_pipeline_state(series_id: str) -> dict[str, Any]:
    """Return pipeline stage status with last job per stage."""
    series = get_series_by_id(series_id)
    if series is None:
        raise HTTPException(status_code=404, detail="series not found")

    state = pipeline_status(series_id, series=series)
    jobs = list_jobs(series_id=series_id, limit=100)

    last_job_by_command: dict[str, dict[str, str]] = {}
    for j in jobs:
        cmd = j.command
        if cmd in _STAGE_COMMANDS and cmd not in last_job_by_command:
            last_job_by_command[cmd] = {
                "job_id": j.id,
                "status": j.status,
                "created_at": j.created_at,
            }

    stages = []
    for i, label in enumerate(state.step_labels):
        cmd = _STAGE_COMMANDS[i] if i < len(_STAGE_COMMANDS) else label.lower()
        job_info = last_job_by_command.get(cmd)
        stages.append(
            {
                "label": label,
                "command": cmd,
                "status": state.step_statuses[i],
                "last_job": job_info,
            }
        )

    return {
        "series_id": series_id,
        "current_step": state.current_step,
        "next_action": next_action(series_id, state=state),
        "stages": stages,
    }
