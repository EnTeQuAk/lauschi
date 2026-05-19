"""Catalog browsing and series detail routes."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from lauschi_catalog.web.catalog_db import (
    get_all_series,
    get_series_by_id,
    sync_catalog_to_db,
)
from lauschi_catalog.web.config import CURATION_DIR, REPO_ROOT, SERIES_LOCK, SERIES_YAML
from lauschi_catalog.web.jobs import get_active_job, list_jobs
from lauschi_catalog.web.pipeline import next_action, pipeline_status
from lauschi_catalog.web.utils import safe_write_json, safe_write_yaml

router = APIRouter()


@router.get("/pipeline", response_class=HTMLResponse)
async def pipeline_overview(request: Request):
    """Show all series with their pipeline state and next actions."""
    all_series = get_all_series()
    enriched = []
    for s in all_series:
        state = pipeline_status(s.id, series=s)
        enriched.append(
            {
                "id": s.id,
                "title": s.title,
                "content_type": s.content_type or "hoerspiel",
                "status": state.status,
                "current_step": state.current_step,
                "current_label": state.current_label,
                "pipeline": {
                    "labels": state.step_labels,
                    "statuses": state.step_statuses,
                },
                "next_action": next_action(s.id, state=state),
            }
        )
    return templates.TemplateResponse(
        request,
        "pipeline.html",
        {"series": enriched},
    )


BASE_DIR = Path(__file__).resolve().parent.parent
TEMPLATES_DIR = BASE_DIR / "templates"
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))
templates.env.globals["zip"] = zip  # type: ignore[reportArgumentType]


@router.get("/catalog", response_class=HTMLResponse)
async def catalog_list(request: Request, q: str = ""):
    all_series = get_all_series()
    series = all_series
    if q:
        term = q.lower()
        series = [s for s in series if term in s.title.lower() or term in s.id.lower()]

    enriched = []
    for s in series:
        state = pipeline_status(s.id, series=s)
        enriched.append(
            {
                "id": s.id,
                "title": s.title,
                "content_type": s.content_type or "hoerspiel",
                "providers": list(s.providers.keys()),
                "status": state.status,
                "current_step": state.current_step,
                "current_label": state.current_label,
                "pipeline": {
                    "labels": state.step_labels,
                    "statuses": state.step_statuses,
                },
                "next_action": next_action(s.id, state=state),
            }
        )
    return templates.TemplateResponse(
        request,
        "catalog_list.html",
        {"series": enriched, "q": q, "total": len(all_series)},
    )


def _render_series_detail(
    request: Request,
    series_id: str,
    *,
    tab: str = "episodes",
    errors: dict[str, str] | None = None,
    form_data: dict[str, str] | None = None,
) -> HTMLResponse:
    """Render the series detail page."""
    series = get_series_by_id(series_id)
    if series is None:
        return HTMLResponse("Series not found", status_code=404)

    curation_path = CURATION_DIR / f"{series_id}.json"
    curation = None
    if curation_path.exists():
        curation = json.loads(curation_path.read_text())

    pipe_state = pipeline_status(series_id, series=series)
    pipeline = {
        "labels": pipe_state.step_labels,
        "statuses": pipe_state.step_statuses,
        "current_step": pipe_state.current_step,
        "current_label": pipe_state.current_label,
        "status": pipe_state.status,
    }

    active_job = get_active_job(series_id)

    # Episode coverage: which providers cover each episode number
    coverage: dict[str, Any] | None = None
    if curation and curation.get("albums"):
        albums = curation["albums"]
        providers = sorted({a.get("provider") for a in albums if a.get("provider")})
        # Episode number -> set of providers with an included album
        episode_providers: dict[int, set[str]] = {}
        for a in albums:
            if a.get("include") and a.get("episode_num") is not None:
                ep = a["episode_num"]
                if ep not in episode_providers:
                    episode_providers[ep] = set()
                episode_providers[ep].add(a.get("provider", ""))

        max_ep = max(episode_providers.keys()) if episode_providers else 0
        # Build per-episode coverage list up to max_ep
        episodes = []
        for ep in range(1, max_ep + 1):
            eps = episode_providers.get(ep, set())
            episodes.append(
                {
                    "num": ep,
                    "providers": {p: p in eps for p in providers},
                    "missing": not eps,
                }
            )

        coverage = {
            "providers": providers,
            "max_episode": max_ep,
            "episodes": episodes,
            "stats": {
                p: len([ep for ep in episodes if ep["providers"][p]]) for p in providers
            },
        }

    return templates.TemplateResponse(
        request,
        "series_detail.html",
        {
            "series": series,
            "curation": curation,
            "pipeline": pipeline,
            "tab": tab,
            "errors": errors or {},
            "form_data": form_data or {},
            "active_job": active_job,
            "coverage": coverage,
        },
    )


@router.get("/catalog/{series_id}", response_class=HTMLResponse)
async def series_detail(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="episodes")


@router.get("/catalog/{series_id}/curation", response_class=HTMLResponse)
async def series_curation(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="curation")


@router.get("/catalog/{series_id}/audit", response_class=HTMLResponse)
async def series_audit(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="audit")


@router.get("/catalog/{series_id}/edit", response_class=HTMLResponse)
async def series_edit(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="edit")


@router.post("/catalog/{series_id}/edit", response_class=HTMLResponse)
async def series_edit_post(request: Request, series_id: str):
    """Handle edit form submission."""
    from filelock import FileLock

    from lauschi_catalog.catalog.loader import load_raw

    series = get_series_by_id(series_id)
    if series is None:
        return HTMLResponse("Series not found", status_code=404)

    form = await request.form()
    errors: dict[str, str] = {}

    title = str(form.get("title", "")).strip()
    new_id = str(form.get("id", "")).strip()
    aliases_text = str(form.get("aliases", "")).strip()
    episode_pattern = str(form.get("episode_pattern", "")).strip()
    content_type = str(form.get("content_type", "hoerspiel")).strip()

    # Validation
    if not title:
        errors["title"] = "Title is required"
    if not re.match(r"^[a-z][a-z0-9_]*$", new_id):
        errors["id"] = "ID must be snake_case"
    else:
        all_series = get_all_series()
        existing = [s.id for s in all_series if s.id != series_id]
        if new_id in existing:
            errors["id"] = f"ID '{new_id}' already exists"

    if episode_pattern:
        try:
            compiled = re.compile(episode_pattern)
            if compiled.groups < 1:
                errors["episode_pattern"] = "Pattern needs at least 1 capture group"
        except re.error as e:
            errors["episode_pattern"] = f"Invalid regex: {e}"

    if content_type not in ("hoerspiel", "music"):
        errors["content_type"] = "Must be 'hoerspiel' or 'music'"

    if errors:
        return _render_series_detail(
            request,
            series_id,
            tab="edit",
            errors=errors,
            form_data={
                "title": title,
                "id": new_id,
                "aliases": aliases_text,
                "episode_pattern": episode_pattern,
                "content_type": content_type,
            },
        )

    # Apply changes
    aliases = [a.strip() for a in aliases_text.split(",") if a.strip()]

    with FileLock(str(SERIES_LOCK)):
        data = load_raw(SERIES_YAML)
        raw_entry = None
        for entry in data["series"]:
            if entry.get("id") == series_id:
                raw_entry = entry
                break

        if raw_entry is None:
            return HTMLResponse("Series not found in series.yaml", status_code=404)

        raw_entry["title"] = title
        if new_id != series_id:
            raw_entry["id"] = new_id
        if aliases:
            raw_entry["aliases"] = aliases
        elif "aliases" in raw_entry:
            del raw_entry["aliases"]
        if episode_pattern:
            raw_entry["episode_pattern"] = episode_pattern
        elif "episode_pattern" in raw_entry:
            del raw_entry["episode_pattern"]
        if content_type != "hoerspiel":
            raw_entry["content_type"] = content_type
        elif "content_type" in raw_entry:
            del raw_entry["content_type"]

        safe_write_yaml(SERIES_YAML, data)

    # Rename curation file if ID changed
    if new_id != series_id:
        old_curation = CURATION_DIR / f"{series_id}.json"
        new_curation = CURATION_DIR / f"{new_id}.json"
        if old_curation.exists():
            old_curation.rename(new_curation)
            curation = json.loads(new_curation.read_text())
            curation["id"] = new_id
            safe_write_json(new_curation, curation)

    # Sync DB and redirect
    sync_catalog_to_db()
    return RedirectResponse(url=f"/catalog/{new_id}", status_code=303)


@router.get("/review", response_class=HTMLResponse)
async def review_queue(request: Request):
    """Show all series that need human attention (escalated or missing curation)."""
    all_series = get_all_series()
    needs_review = []
    for s in all_series:
        state = pipeline_status(s.id, series=s)
        if state.status in ("escalated", "missing"):
            needs_review.append(
                {
                    "id": s.id,
                    "title": s.title,
                    "content_type": s.content_type or "hoerspiel",
                    "status": state.status,
                    "current_label": state.current_label,
                    "next_action": next_action(s.id, state=state),
                }
            )
    return templates.TemplateResponse(
        request,
        "review_queue.html",
        {"series": needs_review},
    )


@router.post("/catalog/{series_id}/run", response_class=RedirectResponse)
async def series_run_post(request: Request, series_id: str):
    """Queue a pipeline command for a series (curate/audit/apply/validate)."""
    from lauschi_catalog.web.jobs import create_job, get_active_job
    from lauschi_catalog.web.routes.jobs_api import run_subprocess

    series = get_series_by_id(series_id)
    if series is None:
        return HTMLResponse("Series not found", status_code=404)

    form = await request.form()
    command = str(form.get("command", "")).strip()
    if command not in (
        "curate",
        "audit",
        "apply",
        "validate",
        "discover",
        "pipeline-one",
    ):
        return RedirectResponse(url=f"/catalog/{series_id}/curation", status_code=303)

    existing = get_active_job(series_id)
    if existing:
        # Show flash via query param
        return RedirectResponse(
            url=f"/catalog/{series_id}/curation?flash=job-{existing.command}-already-running",
            status_code=303,
        )

    job_id = create_job(series_id, command)
    run_subprocess(job_id, series_id, command)
    return RedirectResponse(url=f"/catalog/{series_id}/curation", status_code=303)


@router.get("/validate", response_class=HTMLResponse)
async def validate_page(request: Request):
    """Validation trigger page."""
    return templates.TemplateResponse(
        request,
        "validate.html",
        {},
    )


@router.post("/validate/run", response_class=RedirectResponse)
async def validate_run_post(request: Request):
    """Queue full catalog validation job."""
    from lauschi_catalog.web.jobs import create_job
    from lauschi_catalog.web.routes.jobs_api import run_subprocess

    job_id = create_job("all", "validate")
    run_subprocess(job_id, "all", "validate")
    return RedirectResponse(url="/validate", status_code=303)


@router.get("/merge", response_class=HTMLResponse)
async def merge_page(request: Request, message: str = "", error: str = ""):
    """Merge two series."""
    all_series = get_all_series()
    return templates.TemplateResponse(
        request,
        "merge.html",
        {
            "series": [{"id": s.id, "title": s.title} for s in all_series],
            "message": message,
            "error": error,
        },
    )


@router.post("/merge", response_class=RedirectResponse)
async def merge_post(request: Request):
    """Handle merge form submission."""
    from filelock import FileLock

    from lauschi_catalog.catalog.loader import load_raw

    form = await request.form()
    source_id = str(form.get("source_id", "")).strip()
    target_id = str(form.get("target_id", "")).strip()

    if source_id == target_id:
        return RedirectResponse(
            url="/merge?error=source+and+target+must+be+different", status_code=303
        )

    source = get_series_by_id(source_id)
    target = get_series_by_id(target_id)
    if source is None:
        return RedirectResponse(url="/merge?error=source+not+found", status_code=303)
    if target is None:
        return RedirectResponse(url="/merge?error=target+not+found", status_code=303)

    source_curation_path = CURATION_DIR / f"{source_id}.json"
    target_curation_path = CURATION_DIR / f"{target_id}.json"

    if not source_curation_path.exists():
        return RedirectResponse(
            url="/merge?error=source+curation+not+found", status_code=303
        )

    source_curation = json.loads(source_curation_path.read_text())
    source_albums = source_curation.get("albums", [])

    if target_curation_path.exists():
        target_curation = json.loads(target_curation_path.read_text())
        target_albums = target_curation.get("albums", [])
    else:
        target_curation = {
            "id": target_id,
            "title": target.title,
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

    safe_write_json(target_curation_path, target_curation)

    with FileLock(str(SERIES_LOCK)):
        data: dict[str, Any] = load_raw(SERIES_YAML)  # type: ignore[assignment]
        data["series"] = [s for s in data["series"] if s.get("id") != source_id]
        safe_write_yaml(SERIES_YAML, data)

    source_curation_path.unlink()
    sync_catalog_to_db()
    return RedirectResponse(
        url=f"/merge?message=Merged%20{added}%20albums%2C%20skipped%20{skipped}%20duplicates",
        status_code=303,
    )


@router.get("/splits", response_class=HTMLResponse)
async def splits_page(request: Request):
    """Show all series with pending split proposals."""
    all_series = get_all_series()
    pending = []
    for s in all_series:
        curation_path = CURATION_DIR / f"{s.id}.json"
        if not curation_path.exists():
            continue
        data = json.loads(curation_path.read_text())
        review = data.get("review", {})
        splits = review.get("splits", [])
        if splits:
            pending.append(
                {
                    "series_id": s.id,
                    "title": s.title,
                    "splits": splits,
                }
            )
    return templates.TemplateResponse(
        request,
        "splits.html",
        {"splits": pending},
    )


@router.get("/jobs", response_class=HTMLResponse)
async def jobs_page(request: Request):
    """Show all jobs with status and logs."""
    jobs = list_jobs(limit=100)
    return templates.TemplateResponse(
        request,
        "jobs.html",
        {
            "jobs": [
                {
                    "id": j.id,
                    "series_id": j.series_id,
                    "command": j.command,
                    "status": j.status,
                    "log_count": len(j.log_lines),
                    "created_at": j.created_at,
                    "updated_at": j.updated_at,
                    "error": j.error,
                }
                for j in jobs
            ]
        },
    )


@router.post("/catalog/add", response_class=RedirectResponse)
async def add_series(request: Request):
    """Queue a job to add a new series to the catalog."""
    from lauschi_catalog.web.jobs import create_job
    from lauschi_catalog.web.routes.jobs_api import run_custom_subprocess

    form = await request.form()
    title = str(form.get("title", "")).strip()
    if not title:
        return RedirectResponse(url="/catalog?error=title+required", status_code=303)

    spotify_id = str(form.get("spotify_artist_id", "")).strip()
    apple_id = str(form.get("apple_music_artist_id", "")).strip()

    cmd = ["uv", "run", "lauschi-catalog", "add", title]
    if spotify_id:
        cmd.extend(["--spotify-artist-id", spotify_id])
    if apple_id:
        cmd.extend(["--apple-music-artist-id", apple_id])

    job_id = create_job("_new_", "add")
    tools_dir = str(REPO_ROOT / "tools")
    run_custom_subprocess(job_id, cmd, tools_dir)
    return RedirectResponse(url="/jobs", status_code=303)
