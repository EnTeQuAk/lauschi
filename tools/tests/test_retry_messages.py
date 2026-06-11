"""Pin that retry progress messages carry the HTTP error detail.

A bare type name ("failed (ModelHTTPError)") leaves the operator
blind: a 429 quota problem, a 500 capacity blip, and a gateway
timeout all look identical in the run log but demand different
responses (wait for quota vs ride it out vs raise client timeout).
"""

from __future__ import annotations

import asyncio

from pydantic_ai import ModelHTTPError

from lauschi_catalog.rate_limit import run_with_rate_limit_retry


def _run(coro_factory, messages):
    return asyncio.run(run_with_rate_limit_retry(
        coro_factory,
        phase="batch 2/4",
        base_delay=0.01,
        on_progress=messages.append,
    ))


def test_retry_message_includes_status_and_body():
    messages: list[str] = []
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise ModelHTTPError(
                status_code=500,
                model_name="some-hosted-model",
                body={"error": "capacity temporarily exceeded"},
            )
        return "ok"

    assert _run(lambda: flaky(), messages) == "ok"
    assert any(
        "500" in m and "capacity temporarily exceeded" in m for m in messages
    ), messages


def test_retry_message_unwraps_chained_http_error():
    """pydantic-ai wraps transport errors; the status must surface
    even when the outermost type is generic."""
    messages: list[str] = []
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            try:
                raise ModelHTTPError(
                    status_code=503, model_name="m", body="upstream unavailable",
                )
            except ModelHTTPError as inner:
                raise RuntimeError("model request failed") from inner
        return "ok"

    assert _run(lambda: flaky(), messages) == "ok"
    assert any("503" in m for m in messages), messages


def test_retry_message_falls_back_to_str_for_plain_errors():
    messages: list[str] = []
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("connection reset by peer")
        return "ok"

    assert _run(lambda: flaky(), messages) == "ok"
    assert any("connection reset by peer" in m for m in messages), messages
