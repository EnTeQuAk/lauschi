"""Tests for the job subprocess runner (_stream_proc).

Verifies that job status always reaches a terminal state, returncode
is handled correctly, and the safety net catches edge cases.
"""

from __future__ import annotations

import asyncio
import sys

import pytest

from lauschi_catalog.web.jobs import get_job, init_db, reap_zombie_jobs, set_status


@pytest.fixture(autouse=True)
def _setup_db(tmp_path, monkeypatch):
    """Point the job DB at a temp file for each test."""
    db_path = tmp_path / "test_jobs.db"
    monkeypatch.setattr("lauschi_catalog.web.config.JOBS_DB_PATH", db_path)
    monkeypatch.setattr("lauschi_catalog.web.jobs.JOBS_DB_PATH", db_path)
    init_db()


def _create_job(series_id: str = "test", command: str = "test") -> str:
    from lauschi_catalog.web.jobs import create_job

    return create_job(series_id, command)


class TestStreamProc:
    """Core _stream_proc behavior."""

    def test_successful_command_sets_done(self):
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        asyncio.run(_stream_proc(job_id, [sys.executable, "-c", "print('hello')"], "."))
        job = get_job(job_id)
        assert job is not None
        assert job.status == "done"
        assert "hello" in job.log_lines

    def test_failing_command_sets_error(self):
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        asyncio.run(
            _stream_proc(job_id, [sys.executable, "-c", "raise SystemExit(42)"], ".")
        )
        job = get_job(job_id)
        assert job is not None
        assert job.status == "error"
        assert "exit code 42" in (job.error or "")

    def test_multiline_output_captured(self):
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        script = "import sys; [print(f'line {i}') for i in range(5)]"
        asyncio.run(_stream_proc(job_id, [sys.executable, "-c", script], "."))
        job = get_job(job_id)
        assert job is not None
        assert job.status == "done"
        assert len(job.log_lines) == 5
        assert job.log_lines[0] == "line 0"
        assert job.log_lines[4] == "line 4"

    def test_stderr_merged_into_stdout(self):
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        script = "import sys; print('out'); print('err', file=sys.stderr)"
        asyncio.run(_stream_proc(job_id, [sys.executable, "-c", script], "."))
        job = get_job(job_id)
        assert job is not None
        assert "out" in job.log_lines
        assert "err" in job.log_lines

    def test_nonexistent_command_sets_error(self):
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        asyncio.run(_stream_proc(job_id, ["__nonexistent_command_12345__"], "."))
        job = get_job(job_id)
        assert job is not None
        assert job.status == "error"
        assert "FileNotFoundError" in (job.error or "") or "No such file" in (
            job.error or ""
        )

    def test_fast_exit_still_sets_done(self):
        """Regression: fast-exiting processes previously left returncode as None."""
        from lauschi_catalog.web.routes.jobs_api import _stream_proc

        job_id = _create_job()
        asyncio.run(_stream_proc(job_id, [sys.executable, "-c", "pass"], "."))
        job = get_job(job_id)
        assert job is not None
        assert job.status == "done"


class TestReapZombieJobs:
    """reap_zombie_jobs marks stale running/queued jobs as errored on startup."""

    def test_reaps_running_and_queued_jobs(self):
        j1 = _create_job("s1", "curate")
        j2 = _create_job("s2", "discover")
        j3 = _create_job("s3", "audit")
        set_status(j1, "running")
        set_status(j2, "queued")
        set_status(j3, "done")

        reaped = reap_zombie_jobs()
        assert reaped == 2
        assert get_job(j1).status == "error"
        assert "reaped" in get_job(j1).error
        assert get_job(j2).status == "error"
        assert get_job(j3).status == "done"

    def test_returns_zero_when_nothing_to_reap(self):
        j1 = _create_job("s1", "curate")
        set_status(j1, "done")
        assert reap_zombie_jobs() == 0


class TestInProcessErrorPropagation:
    """In-process async jobs must set status=error when the wrapped function fails."""

    def test_async_job_sets_error_on_raised_exception(self):
        from lauschi_catalog.web.routes.jobs_api import launch_in_process_async

        job_id = _create_job()

        async def _failing(*, on_progress):
            on_progress("starting")
            raise RuntimeError("curation failed")

        async def run():
            launch_in_process_async(job_id, _failing)
            await asyncio.sleep(0.2)

        asyncio.run(run())
        job = get_job(job_id)
        assert job.status == "error"
        assert "curation failed" in (job.error or "")

    def test_async_job_sets_done_on_success(self):
        from lauschi_catalog.web.routes.jobs_api import launch_in_process_async

        job_id = _create_job()

        async def _ok(*, on_progress):
            on_progress("done")

        async def run():
            launch_in_process_async(job_id, _ok)
            await asyncio.sleep(0.2)

        asyncio.run(run())
        job = get_job(job_id)
        assert job.status == "done"


class TestSafetyNet:
    """The _cleanup callback catches stuck jobs."""

    def test_cleanup_catches_stuck_running_status(self):
        """If _stream_proc somehow leaves status as 'running', cleanup fixes it."""
        from lauschi_catalog.web.routes.jobs_api import _launch_task

        job_id = _create_job()

        async def run():
            # Manually set to running, then launch a task that immediately
            # raises (simulating a failure before status update).
            set_status(job_id, "running")

            # Patch _stream_proc to raise without updating status
            import lauschi_catalog.web.routes.jobs_api as mod

            original = mod._stream_proc

            async def broken_stream_proc(jid, cmd, cwd):
                raise RuntimeError("simulated crash before status update")

            mod._stream_proc = broken_stream_proc
            try:
                _launch_task(job_id, ["dummy"], ".")
                # Give the task time to run and trigger cleanup
                await asyncio.sleep(0.1)
            finally:
                mod._stream_proc = original

        asyncio.run(run())
        job = get_job(job_id)
        assert job is not None
        assert job.status == "error", f"expected 'error', got {job.status!r}"
