"""A model call that fails on its own gets a fresh start before the
series pays for it."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import BatchResult, _run_batch_attempts
from lauschi_catalog.run import run_with_attempts


def _flaky(fail_times: int, result="ok"):
    calls = {"n": 0}

    async def call():
        calls["n"] += 1
        if calls["n"] <= fail_times:
            raise RuntimeError(f"boom {calls['n']}")
        return result

    return call, calls


class TestRunWithAttempts:
    def test_a_call_that_fails_once_succeeds_on_the_fresh_attempt(self) -> None:
        call, calls = _flaky(1)
        progress: list[str] = []
        out = asyncio.run(
            run_with_attempts(
                call, attempts=3, label="audit", on_progress=progress.append
            )
        )
        assert out == "ok"
        assert calls["n"] == 2
        assert progress == [
            "    audit attempt 1/3 failed: RuntimeError: boom 1. Retrying from a fresh context."
        ]

    def test_the_last_failure_is_raised_after_the_final_attempt(self) -> None:
        call, calls = _flaky(99)
        with pytest.raises(RuntimeError, match="boom 3"):
            asyncio.run(
                run_with_attempts(
                    call, attempts=3, label="x", on_progress=lambda m: None
                )
            )
        assert calls["n"] == 3

    def test_a_clean_call_runs_once(self) -> None:
        call, calls = _flaky(0)
        assert (
            asyncio.run(
                run_with_attempts(
                    call, attempts=3, label="x", on_progress=lambda m: None
                )
            )
            == "ok"
        )
        assert calls["n"] == 1


@pytest.fixture
def log_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(curate_ops, "log_dir", lambda: tmp_path / "logs")
    return tmp_path / "logs"


class TestBatchAttempts:
    def test_a_batch_that_fails_once_completes_and_leaves_evidence(
        self, log_dir: Path
    ) -> None:
        call, calls = _flaky(1, result=BatchResult(albums=[]))
        progress: list[str] = []
        outcome = asyncio.run(
            _run_batch_attempts(
                call,
                series_id="s",
                batch_num=3,
                n_batches=12,
                prompt="p",
                on_progress=progress.append,
            )
        )
        assert outcome.result is not None and outcome.error == ""
        assert calls["n"] == 2
        assert any(
            "Batch 3/12 attempt 1/2 failed: RuntimeError: boom 1" in p for p in progress
        )
        assert (log_dir / "curate-failures" / "s-batch03.json").is_file()

    def test_a_batch_that_keeps_failing_reports_the_last_error(
        self, log_dir: Path
    ) -> None:
        call, calls = _flaky(99)
        progress: list[str] = []
        outcome = asyncio.run(
            _run_batch_attempts(
                call,
                series_id="s",
                batch_num=3,
                n_batches=12,
                prompt="p",
                on_progress=progress.append,
            )
        )
        assert outcome.result is None
        assert outcome.error == "RuntimeError: boom 2"
        assert calls["n"] == 2
        assert any("failed after 2 attempts" in p for p in progress)
