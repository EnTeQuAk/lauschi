"""A model call that fails on its own gets a fresh start before the
series pays for it."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from pydantic_ai.messages import ModelRequest, ModelResponse, TextPart, UserPromptPart

from lauschi_catalog.catalog import audit_ops, curate_ops
from lauschi_catalog.catalog.audit_ops import dump_audit_failure
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

    def test_on_failure_receives_every_attempt_and_the_captured_exchange(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(curate_ops, "log_dir", lambda: tmp_path / "logs")
        call, calls = _flaky(2, result="ok")
        progress: list[str] = []
        failures: list[tuple[int, str, list[str]]] = []

        def _dump(attempt: int, exc: BaseException, messages: list) -> None:
            failures.append((attempt, describe_failure_short(exc), len(messages)))

        out = asyncio.run(
            run_with_attempts(
                call,
                attempts=3,
                label="b",
                on_progress=progress.append,
                on_failure=_dump,
            )
        )
        assert out == "ok"
        assert calls["n"] == 3
        assert [attempt for attempt, _, _ in failures] == [1, 2]

    def test_on_failure_also_fires_on_the_final_attempt(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(curate_ops, "log_dir", lambda: tmp_path / "logs")
        call, _ = _flaky(99)
        progress: list[str] = []
        failures: list[int] = []

        with pytest.raises(RuntimeError, match="boom 2"):
            asyncio.run(
                run_with_attempts(
                    call,
                    attempts=2,
                    label="b",
                    on_progress=progress.append,
                    on_failure=lambda attempt, exc, messages: failures.append(attempt),
                )
            )
        assert failures == [1, 2]


def describe_failure_short(exc: BaseException) -> str:
    return f"{type(exc).__name__}"


class TestDumpAuditFailure:
    def test_the_exchange_and_the_reason_are_written(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(audit_ops, "log_dir", lambda: tmp_path / "logs")
        messages = [
            ModelRequest(parts=[UserPromptPart(content="audit chunk 1/3")]),
            ModelResponse(parts=[TextPart(content='{"approve": true}')]),
        ]
        try:
            raise RuntimeError("Exceeded maximum output retries (2)")
        except RuntimeError as exc:
            path = dump_audit_failure(
                "benjamin_bluemchen", "chunk 1/3", "overview ...", messages, exc
            )

        assert path.parent == tmp_path / "logs" / "audit-failures"
        data = json.loads(path.read_text(encoding="utf-8"))
        assert data["series_id"] == "benjamin_bluemchen"
        assert data["phase"] == "chunk 1/3"
        assert data["error"] == "RuntimeError: Exceeded maximum output retries (2)"
        assert data["prompt"] == "overview ..."
        assert data["messages"][0]["parts"][0]["part_kind"] == "user-prompt"

    def test_a_slash_in_the_phase_does_not_create_directories(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(audit_ops, "log_dir", lambda: tmp_path / "logs")
        path = dump_audit_failure("s", "chunk 1/3", "p", [], RuntimeError("x"))
        assert path.parent == tmp_path / "logs" / "audit-failures"
