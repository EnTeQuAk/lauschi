"""Lightweight SQLite-backed job queue for long-running AI tasks.

Single-user, in-process: ``asyncio.create_task()`` runs the work and
writes log lines to a shared SQLite row.  SSE endpoints poll the row
and stream deltas to the browser.
"""

from __future__ import annotations

import json
import sqlite3
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from lauschi_catalog.web.config import DB_PATH


def _now() -> str:
    return datetime.now(UTC).isoformat()


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    series_id       TEXT NOT NULL,
    command         TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'queued',
    log_lines_json  TEXT NOT NULL DEFAULT '[]',
    result_json     TEXT,
    error           TEXT,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_jobs_series ON jobs(series_id);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
"""


def _conn() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with _conn() as conn:
        conn.executescript(SCHEMA)
        conn.commit()


def reap_zombie_jobs() -> int:
    """Mark stale running/queued jobs as errored.

    Called at startup to clean up jobs left behind by a previous crash
    or by commands that hung on interactive prompts (e.g. `add` with
    DEVNULL stdin). Returns the number of reaped jobs.
    """
    with _conn() as conn:
        cursor = conn.execute(
            "UPDATE jobs SET status = 'error', error = 'reaped: server restarted while job was active', updated_at = ? "
            "WHERE status IN ('running', 'queued')",
            (_now(),),
        )
        conn.commit()
        return cursor.rowcount


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class Job:
    id: str
    series_id: str
    command: str
    status: str  # queued | running | done | error | cancelled
    log_lines: list[str]
    result_json: str | None
    error: str | None
    created_at: str
    updated_at: str

    @classmethod
    def from_row(cls, row: sqlite3.Row) -> Job:
        return cls(
            id=row["id"],
            series_id=row["series_id"],
            command=row["command"],
            status=row["status"],
            log_lines=json.loads(row["log_lines_json"])
            if row["log_lines_json"]
            else [],
            result_json=row["result_json"],
            error=row["error"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )


# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------


def create_job(series_id: str, command: str) -> str:
    job_id = str(uuid.uuid4())[:8]
    with _conn() as conn:
        conn.execute(
            """
            INSERT INTO jobs (id, series_id, command, status, log_lines_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (job_id, series_id, command, "queued", "[]", _now(), _now()),
        )
        conn.commit()
    return job_id


def get_job(job_id: str) -> Job | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
    return Job.from_row(row) if row else None


def list_jobs(series_id: str | None = None, limit: int = 50) -> list[Job]:
    with _conn() as conn:
        if series_id:
            rows = conn.execute(
                "SELECT * FROM jobs WHERE series_id = ? ORDER BY created_at DESC LIMIT ?",
                (series_id, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
    return [Job.from_row(r) for r in rows]


def get_active_job(series_id: str) -> Job | None:
    """Return the most recently queued/running job for a series, or None."""
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE series_id = ? AND status IN ('queued', 'running') ORDER BY created_at DESC LIMIT 1",
            (series_id,),
        ).fetchone()
    return Job.from_row(row) if row else None


def append_log(job_id: str, line: str) -> None:
    """Append a single line to the job's log buffer."""
    with _conn() as conn:
        conn.execute(
            """
            UPDATE jobs
            SET log_lines_json = json_insert(log_lines_json, '$[#]', ?),
                updated_at = ?
            WHERE id = ?
            """,
            (line, _now(), job_id),
        )
        conn.commit()


def set_status(job_id: str, status: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE jobs SET status = ?, updated_at = ? WHERE id = ?",
            (status, _now(), job_id),
        )
        conn.commit()


def set_done(job_id: str, result_json: str | None = None) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE jobs SET status = ?, result_json = ?, updated_at = ? WHERE id = ?",
            ("done", result_json, _now(), job_id),
        )
        conn.commit()


def set_error(job_id: str, error: str) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE jobs SET status = ?, error = ?, updated_at = ? WHERE id = ?",
            ("error", error, _now(), job_id),
        )
        conn.commit()


# ---------------------------------------------------------------------------
# Progress callback (injected into the catalog library)
# ---------------------------------------------------------------------------


def make_progress_callback(job_id: str) -> Callable[[str], None]:
    """Return a callback that appends lines to the given job's log."""

    def _callback(line: str) -> None:
        append_log(job_id, line)

    return _callback
