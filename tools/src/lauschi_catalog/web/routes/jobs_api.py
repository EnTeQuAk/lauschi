"""API routes for job queue and SSE streaming."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
import traceback
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import RedirectResponse, StreamingResponse

from lauschi_catalog.catalog.paths import repo_root
from lauschi_catalog.web.jobs import (
    append_log,
    create_job,
    get_active_job,
    get_job,
    list_jobs,
    set_done,
    set_error,
    set_status,
)
from lauschi_catalog.web.pipeline import pipeline_status

log = logging.getLogger(__name__)

router = APIRouter()

# Track subprocess processes and their owning asyncio tasks for cancellation.
_active_procs: dict[str, asyncio.subprocess.Process] = {}
_active_tasks: dict[str, asyncio.Task[None]] = {}


@router.post("/jobs", response_model=None)
async def queue_job(request: Request):
    """Queue a new AI job. Body: {series_id, command}. Form POSTs redirect back."""
    content_type = request.headers.get("content-type", "")
    is_form = (
        "application/x-www-form-urlencoded" in content_type
        or "multipart/form-data" in content_type
    )
    if is_form:
        body = await request.form()
    else:
        body = await request.json()
    series_id = body.get("series_id")
    command = body.get("command")
    if not series_id or not command:
        if is_form:
            return RedirectResponse(url="/jobs?error=bad+request", status_code=303)
        raise HTTPException(status_code=400, detail="series_id and command required")
    existing = get_active_job(series_id)
    if existing:
        if is_form:
            return RedirectResponse(url="/jobs?error=already+running", status_code=303)
        raise HTTPException(
            status_code=409,
            detail=f"Active job already running for {series_id}: {existing.command} ({existing.id})",
        )
    job_id = create_job(series_id, command)
    run_subprocess(job_id, series_id, command)
    if is_form:
        return RedirectResponse(url="/jobs", status_code=303)
    return {"job_id": job_id}


def _build_cli_args(series_id: str, command: str) -> tuple[list[str], str]:
    """Return subprocess args and cwd for a catalog CLI command.

    Normal commands: ``uv run lauschi-catalog <command> <series_id>``
    Discover: ``uv run lauschi-catalog discover <series_id> --write``
    Pipeline: a shell script that runs all remaining steps from current state.
    Pipeline-one: forcefully re-runs curate -> audit -> apply.
    """
    tools_dir = str(repo_root() / "tools")
    curation_dir = str(repo_root() / "assets" / "catalog" / "curation")
    safe_series = shlex.quote(series_id)

    if command == "discover":
        return (
            ["uv", "run", "lauschi-catalog", "discover", series_id, "--write"],
            tools_dir,
        )

    if command == "pipeline":
        state = pipeline_status(series_id)
        steps = ["discover", "curate", "audit", "apply"]
        remaining: list[str] = []
        if state.current_step < 0:
            remaining = steps
        elif state.current_step < len(steps):
            remaining = steps[state.current_step :]

        script_lines = [f'cd "{tools_dir}"']
        for step in remaining:
            if step == "discover":
                script_lines.append(
                    f"uv run lauschi-catalog discover {safe_series} --write"
                )
            else:
                script_lines.append(f"uv run lauschi-catalog {step} {safe_series}")

        script = "\n".join(script_lines)
        return (
            ["bash", "-c", script],
            str(repo_root()),
        )

    if command == "pipeline-one":
        timeout = "7200"
        script = f'''set -euo pipefail
cd "{tools_dir}"
echo "Step 1/5: Discovering {safe_series}..."
uv run lauschi-catalog discover {safe_series} --write

echo ""
echo "Step 2/5: Curating {safe_series}..."
uv run --extra ai lauschi-catalog curate {safe_series} --timeout {timeout} --force

echo ""
echo "Step 3/5: Auditing (4-eye)..."
uv run --extra ai lauschi-catalog audit {safe_series} --timeout {timeout} --force

echo ""
echo "Step 4/5: Checking audit status..."
STATUS=$(python3 -c "
import json, sys
from pathlib import Path
p = Path('{curation_dir}') / f'{safe_series}.json'
if not p.exists(): print('missing'); sys.exit(0)
d = json.loads(p.read_text())
print(d.get('review', {{}}).get('status', 'curated'))
")
if [ "$STATUS" = "escalated" ]; then
    echo "Audit escalated. Apply and validate skipped."
    exit 1
fi

echo "Applying..."
uv run lauschi-catalog apply {safe_series}

echo ""
echo "Step 5/5: Validating..."
uv run lauschi-catalog validate
echo "Done."
'''
        return (
            ["bash", "-c", script],
            str(repo_root()),
        )

    if command == "validate":
        # validate supports --series to filter to one series
        return (
            ["uv", "run", "lauschi-catalog", "validate", "--series", series_id],
            tools_dir,
        )

    # Default: curate, audit, apply
    return (
        ["uv", "run", "lauschi-catalog", command, series_id],
        tools_dir,
    )


def _force_status(job_id: str, status: str, error: str | None = None) -> None:
    """Best-effort status update that never raises.

    Used in finally blocks and cleanup callbacks where we must not let
    a DB error prevent the rest of the teardown from running.
    """
    try:
        if status == "done":
            set_done(job_id)
        elif status == "error":
            set_error(job_id, error or "unknown error")
        else:
            set_status(job_id, status)
    except Exception:
        log.exception("job %s: failed to set status to %r in DB", job_id, status)


async def _stream_proc(job_id: str, cmd: list[str], cwd: str) -> None:
    """Run a subprocess, stream stdout to job log, update status on exit.

    Guarantees:
    - Status is always updated to a terminal state (done/error/cancelled),
      even if the DB write fails on first attempt.
    - ``proc.wait()`` is always called so returncode is set.
    - All exceptions are caught and logged.
    """
    log.info("job %s: starting subprocess: %s (cwd=%s)", job_id, cmd, cwd)
    set_status(job_id, "running")

    final_status = "error"
    final_error: str | None = "process never started"
    proc: asyncio.subprocess.Process | None = None

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=cwd,
            env={**os.environ, "PYTHONUNBUFFERED": "1"},
        )
        _active_procs[job_id] = proc
        log.info("job %s: subprocess started (pid=%d)", job_id, proc.pid)
        assert proc.stdout is not None

        await _read_output(job_id, proc)

        # Ensure the process has fully exited and returncode is set.
        await proc.wait()
        log.info("job %s: subprocess exited (rc=%s, pid=%d)", job_id, proc.returncode, proc.pid)

        if proc.returncode == 0:
            final_status = "done"
            final_error = None
        else:
            final_status = "error"
            final_error = f"exit code {proc.returncode}"

    except asyncio.CancelledError:
        final_status = "cancelled"
        final_error = None
        log.info("job %s: task cancelled", job_id)
        if proc and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                proc.kill()
                log.warning("job %s: had to SIGKILL subprocess", job_id)
        raise

    except Exception as e:
        final_status = "error"
        final_error = f"{type(e).__name__}: {e}\n{traceback.format_exc()}"
        log.exception("job %s: unhandled exception in _stream_proc", job_id)

    finally:
        log.info("job %s: finalizing with status=%r", job_id, final_status)
        _force_status(job_id, final_status, final_error)


async def _read_output(job_id: str, proc: asyncio.subprocess.Process) -> None:
    """Read subprocess stdout line by line, appending each to the job log.

    Uses a simple read loop. If the process exits but a grandchild holds
    the pipe open, we race against proc.wait() and drain with a timeout.
    """
    assert proc.stdout is not None

    while True:
        # Race readline against process exit to avoid hanging if a
        # grandchild keeps stdout open after the main process exits.
        read_task = asyncio.create_task(proc.stdout.readline())
        wait_task = asyncio.create_task(proc.wait())

        done, pending = await asyncio.wait(
            {read_task, wait_task},
            return_when=asyncio.FIRST_COMPLETED,
        )

        if read_task in done:
            for t in pending:
                t.cancel()
            line_bytes = read_task.result()
            if not line_bytes:
                # EOF on stdout; process may or may not have exited yet.
                break
            text = line_bytes.decode("utf-8", errors="replace").rstrip("\n")
            if text:
                append_log(job_id, text)
        else:
            # Process exited before readline completed. Drain remaining
            # buffered output with a timeout, then stop.
            read_task.cancel()
            try:
                remaining = await asyncio.wait_for(
                    proc.stdout.read(), timeout=2.0
                )
                if remaining:
                    for ln in remaining.decode("utf-8", errors="replace").split("\n"):
                        if ln:
                            append_log(job_id, ln)
            except asyncio.TimeoutError:
                log.warning("job %s: timed out draining stdout after process exit", job_id)
            break


def _launch_task(job_id: str, cmd: list[str], cwd: str) -> None:
    """Create an asyncio task to run _stream_proc with cleanup on completion."""

    async def _runner() -> None:
        await _stream_proc(job_id, cmd, cwd)

    task = asyncio.create_task(_runner())
    _active_tasks[job_id] = task

    def _cleanup(t: asyncio.Task[None]) -> None:
        _active_procs.pop(job_id, None)
        _active_tasks.pop(job_id, None)

        # Safety net: if the task ended but status is still non-terminal
        # (e.g. because _stream_proc's finally block failed), force it.
        try:
            job = get_job(job_id)
            if job and job.status in ("queued", "running"):
                error_detail = "task ended without setting terminal status"
                exc = t.exception() if not t.cancelled() else None
                if exc:
                    error_detail = f"{type(exc).__name__}: {exc}"
                elif t.cancelled():
                    error_detail = "task was cancelled"
                log.error("job %s: safety net triggered, status was %r", job_id, job.status)
                _force_status(job_id, "error", error_detail)
        except Exception:
            log.exception("job %s: safety net itself failed", job_id)

    task.add_done_callback(_cleanup)


def run_subprocess(job_id: str, series_id: str, command: str) -> None:
    """Launch the CLI command as a subprocess and stream lines to the job log."""
    cmd, cwd = _build_cli_args(series_id, command)
    log.info("job %s: queuing subprocess for %s/%s", job_id, series_id, command)
    _launch_task(job_id, cmd, cwd)


def run_custom_subprocess(job_id: str, cmd: list[str], cwd: str) -> None:
    """Run an arbitrary command as a subprocess and stream lines to the job log."""
    log.info("job %s: queuing custom subprocess: %s", job_id, cmd)
    _launch_task(job_id, cmd, cwd)


@router.get("/jobs")
async def get_jobs(series_id: str | None = None) -> list[dict[str, Any]]:
    jobs = list_jobs(series_id)
    return [
        {
            "id": j.id,
            "series_id": j.series_id,
            "command": j.command,
            "status": j.status,
            "log_count": len(j.log_lines),
            "created_at": j.created_at,
            "updated_at": j.updated_at,
        }
        for j in jobs
    ]


@router.get("/jobs/{job_id}/logs")
async def get_job_logs(job_id: str) -> dict[str, Any]:
    """Return all log lines and status for a job (for viewing historical logs)."""
    job = get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return {
        "id": job.id,
        "status": job.status,
        "error": job.error,
        "lines": job.log_lines,
    }


@router.get("/jobs/{job_id}/events")
async def job_events(job_id: str) -> StreamingResponse:
    """SSE endpoint: stream new log lines as they are written.

    Keeps the connection alive indefinitely with periodic heartbeats
    so long-running pipeline jobs (hours) can be monitored.
    """

    async def event_stream():
        last_count = 0
        heartbeat = 0
        while True:
            job = get_job(job_id)
            if job is None:
                yield "event: error\ndata: Job not found\n\n"
                break
            current = len(job.log_lines)
            if current > last_count:
                for line in job.log_lines[last_count:]:
                    payload = json.dumps({"line": line, "status": job.status})
                    yield f"event: log\ndata: {payload}\n\n"
                last_count = current
            if job.status in ("done", "error", "cancelled"):
                payload = json.dumps({"status": job.status, "done": True})
                yield f"event: done\ndata: {payload}\n\n"
                break
            # Heartbeat every 30s to keep connection alive through proxies
            heartbeat += 1
            if heartbeat % 60 == 0:
                yield ":heartbeat\n\n"
            await asyncio.sleep(0.5)

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )


@router.post("/jobs/{job_id}/cancel", response_model=None)
async def post_cancel_job(job_id: str, request: Request):
    """Cancel an active job. Works for in-memory tasks and orphaned DB rows.

    Form POSTs redirect back to /jobs so the UI stays on the page.
    """
    content_type = request.headers.get("content-type", "")
    is_form = (
        "application/x-www-form-urlencoded" in content_type
        or "multipart/form-data" in content_type
    )
    cancelled = False
    task = _active_tasks.get(job_id)
    if task and not task.done():
        task.cancel()
        cancelled = True
    proc = _active_procs.get(job_id)
    if proc and proc.returncode is None:
        proc.terminate()
        cancelled = True
    job = get_job(job_id)
    if job and job.status in ("running", "queued"):
        set_status(job_id, "cancelled")
        cancelled = True
    if is_form:
        return RedirectResponse(url="/jobs", status_code=303)
    return {"cancelled": cancelled}


@router.post("/series/{series_id}/apply")
async def apply_series(series_id: str) -> dict[str, str]:
    """Queue an apply job for a series. Writes approved curation to series.yaml."""
    job_id = create_job(series_id, "apply")
    run_subprocess(job_id, series_id, "apply")
    return {"job_id": job_id}
