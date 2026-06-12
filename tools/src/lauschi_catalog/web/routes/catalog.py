"""Catalog browsing and series detail routes."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from lauschi_catalog.catalog.merge_ops import merge_series
from lauschi_catalog.catalog.paths import (
    artist_image_path,
    cover_cache_path,
    curation_path as _curation_path,
    repo_root,
)
from lauschi_catalog.catalog.series_ops import (
    SeriesChanges,
    delete_series,
    edit_series,
    validate_series_changes,
)
from lauschi_catalog.web.catalog_db import (
    get_all_series,
    get_series_by_id,
    sync_catalog_to_db,
)
from lauschi_catalog.web.flash import flash_context, redirect_with_flash
from lauschi_catalog.web.jobs import create_job, get_active_job, get_job, list_jobs
from lauschi_catalog.web.pipeline import next_action, pipeline_status
from lauschi_catalog.web.routes.jobs_api import run_custom_subprocess, run_subprocess

router = APIRouter()


def _series_cover_url(series_id: str) -> str:
    """Load artist image URL (preferred) or first album cover as fallback."""
    artist_cache = artist_image_path(series_id)
    if artist_cache.exists():
        try:
            images = json.loads(artist_cache.read_text())
            url = images.get("spotify") or next(iter(images.values()), "")
            if url:
                return url
        except (json.JSONDecodeError, StopIteration):
            pass
    cache = cover_cache_path(series_id)
    if not cache.exists():
        return ""
    try:
        covers = json.loads(cache.read_text())
        return next(iter(covers.values()), "")
    except (json.JSONDecodeError, StopIteration):
        return ""


def _curation_album_count(series_id: str) -> int:
    """Count included albums in curation JSON."""
    path = _curation_path(series_id)
    if not path.exists():
        return 0
    try:
        data = json.loads(path.read_text())
        return sum(1 for a in data.get("albums", []) if a.get("include"))
    except (json.JSONDecodeError, KeyError):
        return 0


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
templates = Jinja2Templates(
    directory=str(TEMPLATES_DIR), context_processors=[flash_context]
)
templates.env.globals["zip"] = zip  # type: ignore[reportArgumentType]


@router.get("/catalog", response_class=HTMLResponse)
async def catalog_list(request: Request, q: str = "", tab: str = "hoerspiel", status: str = ""):
    all_series = get_all_series()
    series = all_series

    if tab in ("hoerspiel", "music"):
        series = [s for s in series if (s.content_type or "hoerspiel") == tab]

    if q:
        term = q.lower()
        series = [s for s in series if term in s.title.lower() or term in s.id.lower()]

    counts = {"hoerspiel": 0, "music": 0}
    for s in all_series:
        ct = s.content_type or "hoerspiel"
        if ct in counts:
            counts[ct] += 1

    enriched = []
    for s in series:
        ct = s.content_type or "hoerspiel"
        state = pipeline_status(s.id, series=s)
        label = state.current_label if state.status != "escalated" else "Escalated"
        enriched.append(
            {
                "id": s.id,
                "title": s.title,
                "content_type": ct,
                "providers": list(s.providers.keys()),
                "status": state.status,
                "current_step": state.current_step,
                "current_label": state.current_label,
                "filter_label": label,
                "pipeline": {
                    "labels": state.step_labels,
                    "statuses": state.step_statuses,
                },
                "next_action": next_action(s.id, state=state),
                "cover_url": _series_cover_url(s.id),
                "album_count": _curation_album_count(s.id),
            }
        )

    status_counts: dict[str, int] = {}
    for s in enriched:
        status_counts[s["filter_label"]] = status_counts.get(s["filter_label"], 0) + 1

    active_filters = {f for f in status.split(",") if f} if status else set()
    if active_filters:
        enriched = [s for s in enriched if s["filter_label"] in active_filters]

    filter_order = ["Discover", "Curate", "Audit", "Apply", "Validate", "Done", "Escalated"]
    status_filters = [
        {"label": label, "count": status_counts.get(label, 0), "active": label in active_filters}
        for label in filter_order
        if status_counts.get(label, 0) > 0
    ]

    return templates.TemplateResponse(
        request,
        "catalog_list.html",
        {
            "series": enriched,
            "q": q,
            "tab": tab,
            "status": status,
            "counts": counts,
            "total": len(all_series),
            "status_filters": status_filters,
        },
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

    cur_path = _curation_path(series_id)
    curation = None
    if cur_path.exists():
        curation = json.loads(cur_path.read_text())

    # Inject cover URLs and sort-safe episode_num into album dicts
    covers: dict[str, str] = {}
    cache = cover_cache_path(series_id)
    if cache.exists():
        try:
            covers = json.loads(cache.read_text())
        except json.JSONDecodeError:
            pass
    if curation and curation.get("albums"):
        for album in curation["albums"]:
            aid = album.get("album_id") or album.get("id", "")
            if aid in covers:
                album["image_url"] = covers[aid]
            ep = album.get("episode_num")
            album["episode_num_sort"] = ep if ep is not None else 999999

    pipe_state = pipeline_status(series_id, series=series)
    pipeline = {
        "labels": pipe_state.step_labels,
        "statuses": pipe_state.step_statuses,
        "current_step": pipe_state.current_step,
        "current_label": pipe_state.current_label,
        "status": pipe_state.status,
    }

    active_job = get_active_job(series_id)

    # Split relationship: parent and children
    split_from = None
    if series.split_from:
        parent = get_series_by_id(series.split_from)
        if parent:
            split_from = {"id": parent.id, "title": parent.title}
    split_children = [
        {"id": s.id, "title": s.title}
        for s in get_all_series()
        if s.split_from == series_id
    ]

    # Group included albums by episode for the preview tab
    grouped_episodes: list[dict[str, Any]] = []
    if curation and curation.get("albums"):
        by_episode: dict[int | None, list[dict]] = {}
        for a in curation["albums"]:
            if not a.get("include"):
                continue
            ep = a.get("episode_num")
            by_episode.setdefault(ep, []).append(a)

        for ep_num in sorted(by_episode, key=lambda x: x if x is not None else 999999):
            albums_for_ep = by_episode[ep_num]
            providers_present = sorted({a.get("provider", "") for a in albums_for_ep})
            first = albums_for_ep[0]
            image = first.get("image_url", "")
            if not image:
                for a in albums_for_ep:
                    if a.get("image_url"):
                        image = a["image_url"]
                        break
            grouped_episodes.append({
                "episode_num": ep_num,
                "title": first.get("title", ""),
                "image_url": image,
                "release_date": first.get("release_date", ""),
                "providers": providers_present,
            })

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
            "grouped_episodes": grouped_episodes,
            "artist_image_url": _series_cover_url(series_id),
            "coverage": coverage,
            "split_from": split_from,
            "split_children": split_children,
        },
    )


@router.get("/catalog/{series_id}", response_class=HTMLResponse)
async def series_detail(request: Request, series_id: str):
    series = get_series_by_id(series_id)
    if series is None:
        return HTMLResponse("Series not found", status_code=404)
    state = pipeline_status(series_id, series=series)
    active = get_active_job(series_id)
    tab = "preview" if state.status == "done" and not active else "pipeline"
    return _render_series_detail(request, series_id, tab=tab)


@router.get("/catalog/{series_id}/preview", response_class=HTMLResponse)
async def series_preview(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="preview")


@router.get("/catalog/{series_id}/episodes", response_class=HTMLResponse)
async def series_episodes(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="episodes")


@router.get("/catalog/{series_id}/pipeline", response_class=HTMLResponse)
async def series_pipeline(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="pipeline")


@router.get("/catalog/{series_id}/audit", response_class=HTMLResponse)
async def series_audit(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="audit")


@router.get("/catalog/{series_id}/edit", response_class=HTMLResponse)
async def series_edit(request: Request, series_id: str):
    return _render_series_detail(request, series_id, tab="edit")


@router.post("/catalog/{series_id}/delete", response_class=RedirectResponse)
async def series_delete(request: Request, series_id: str):
    """Delete a series: series.yaml entry, curation JSON, deletion log.

    Same path as the CLI delete command; the deletion log keeps
    catalog-add from silently re-introducing the id later.
    """
    form = await request.form()
    reason = str(form.get("reason", "")).strip()
    if not reason:
        return redirect_with_flash(
            f"/catalog/{series_id}/edit", error="A deletion reason is required"
        )

    result = delete_series(series_id, reason=reason)
    if not result.ok:
        return redirect_with_flash(
            f"/catalog/{series_id}/edit", error=result.error or "delete failed"
        )

    sync_catalog_to_db()
    return redirect_with_flash(
        "/catalog", message=f"Deleted {series_id} from the catalog"
    )


@router.post("/catalog/{series_id}/edit", response_class=HTMLResponse)
async def series_edit_post(request: Request, series_id: str):
    """Handle edit form submission."""
    series = get_series_by_id(series_id)
    if series is None:
        return HTMLResponse("Series not found", status_code=404)

    form = await request.form()

    title = str(form.get("title", "")).strip()
    new_id = str(form.get("id", "")).strip()
    aliases_text = str(form.get("aliases", "")).strip()
    episode_pattern = str(form.get("episode_pattern", "")).strip()
    content_type = str(form.get("content_type", "hoerspiel")).strip()

    # Form-level validation (field-specific errors for the template)
    errors: dict[str, str] = {}
    if not title:
        errors["title"] = "Title is required"

    changes = SeriesChanges(
        title=title or None,
        id=new_id or None,
        aliases=[a.strip() for a in aliases_text.split(",") if a.strip()] if aliases_text else None,
        episode_pattern=episode_pattern or None,
        content_type=content_type or None,
    )
    for msg in validate_series_changes(series_id, changes):
        if "id" in msg.lower() and "id" not in errors:
            errors["id"] = msg
        elif "pattern" in msg.lower():
            errors["episode_pattern"] = msg
        elif "content_type" in msg.lower():
            errors["content_type"] = msg

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

    result = edit_series(series_id, changes)
    if not result.ok:
        return HTMLResponse(result.error or "Unknown error", status_code=404)

    sync_catalog_to_db()
    return RedirectResponse(url=f"/catalog/{result.series_id}", status_code=303)


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
        return RedirectResponse(url=f"/catalog/{series_id}/pipeline", status_code=303)

    existing = get_active_job(series_id)
    if existing:
        # Show flash via query param
        return redirect_with_flash(
            f"/catalog/{series_id}/pipeline",
            error=f"A {existing.command} job is already running for this series",
        )

    job_id = create_job(series_id, command)
    run_subprocess(job_id, series_id, command)
    return RedirectResponse(url=f"/catalog/{series_id}/pipeline", status_code=303)


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
    job_id = create_job("all", "validate")
    run_subprocess(job_id, "all", "validate")
    return RedirectResponse(url="/validate", status_code=303)


@router.get("/merge", response_class=HTMLResponse)
async def merge_page(request: Request):
    """Merge two series."""
    all_series = get_all_series()
    return templates.TemplateResponse(
        request,
        "merge.html",
        {"series": [{"id": s.id, "title": s.title} for s in all_series]},
    )


@router.post("/merge", response_class=RedirectResponse)
async def merge_post(request: Request):
    """Handle merge form submission."""
    form = await request.form()
    source_id = str(form.get("source_id", "")).strip()
    target_id = str(form.get("target_id", "")).strip()

    target = get_series_by_id(target_id)
    result = merge_series(
        source_id, target_id,
        target_title=target.title if target else None,
    )
    if not result.ok:
        return redirect_with_flash(
            "/merge", error=result.error or "unknown error",
            status_code=303,
        )

    sync_catalog_to_db()
    return redirect_with_flash(
        "/merge",
        message=f"Merged {result.added} albums, skipped {result.skipped} duplicates",
    )


@router.get("/splits", response_class=HTMLResponse)
async def splits_page(request: Request):
    """Show all series with pending split proposals."""
    all_series = get_all_series()
    pending = []
    for s in all_series:
        cur_path = _curation_path(s.id)
        if not cur_path.exists():
            continue
        data = json.loads(cur_path.read_text())
        subs = data.get("series_facts", {}).get("sub_series", [])
        if not subs:
            continue

        albums = data.get("albums", [])
        album_lookup: dict[str, dict] = {}
        for a in albums:
            key = f"{a.get('provider')}:{a.get('album_id')}"
            album_lookup[key] = a

        enriched_subs = []
        for i, sub in enumerate(subs):
            matched = [
                album_lookup[aid]
                for aid in sub.get("album_ids", [])
                if aid in album_lookup
            ]
            enriched_subs.append({
                "index": i,
                "label": sub.get("label", ""),
                "reason": sub.get("reason", ""),
                "album_ids": sub.get("album_ids", []),
                "albums": sorted(
                    matched,
                    key=lambda a: (a.get("episode_num") or 0, a.get("provider", "")),
                ),
                "default_id": f"{s.id}_{sub.get('label', '')}",
                "default_title": f"{s.title}: {sub.get('label', '').replace('_', ' ').title()}",
            })
        pending.append({
            "series_id": s.id,
            "title": s.title,
            "sub_series": enriched_subs,
        })
    return templates.TemplateResponse(
        request,
        "splits.html",
        {"splits": pending},
    )


@router.get("/jobs/{job_id}", response_class=HTMLResponse)
async def job_detail_page(request: Request, job_id: str):
    """Full-page job detail with terminal output and SSE streaming."""
    job = get_job(job_id)
    if job is None:
        return HTMLResponse("Job not found", status_code=404)
    return templates.TemplateResponse(
        request,
        "job_detail.html",
        {
            "job": {
                "id": job.id,
                "series_id": job.series_id,
                "command": job.command,
                "status": job.status,
                "error": job.error,
                "created_at": job.created_at,
            },
        },
    )


@router.get("/jobs", response_class=HTMLResponse)
async def jobs_page(request: Request):
    """Show all jobs with status and logs."""
    jobs = list_jobs(limit=100)
    jobs_data = [
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
    return templates.TemplateResponse(
        request,
        "jobs.html",
        {
            "jobs": jobs_data,
            "jobs_json": json.dumps(jobs_data),
        },
    )


@router.post("/catalog/add", response_class=RedirectResponse)
async def add_series(request: Request):
    """Queue a job to add a new series to the catalog."""
    form = await request.form()
    title = str(form.get("title", "")).strip()
    if not title:
        return redirect_with_flash("/catalog", error="title required")

    spotify_id = str(form.get("spotify_artist_id", "")).strip()
    apple_id = str(form.get("apple_music_artist_id", "")).strip()

    cmd = ["uv", "run", "lauschi-catalog", "add", title]
    if spotify_id:
        cmd.extend(["--spotify-artist-id", spotify_id])
    if apple_id:
        cmd.extend(["--apple-music-artist-id", apple_id])

    job_id = create_job("_new_", "add")
    tools_dir = str(repo_root() / "tools")
    run_custom_subprocess(job_id, cmd, tools_dir)
    return RedirectResponse(url="/jobs", status_code=303)
