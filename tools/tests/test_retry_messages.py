"""Pin that retry progress messages carry the HTTP error detail.

A bare type name ("failed (ModelHTTPError)") leaves the operator
blind: a 429 quota problem, a 500 capacity blip, and a gateway
timeout all look identical in the run log but demand different
responses (wait for quota vs ride it out vs raise client timeout).
"""

from __future__ import annotations

import asyncio

import pytest
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


def test_timeout_retried_by_default():
    """asyncio.TimeoutError is retried with retry_timeout=True (default),
    matching curate's behavior where timeouts are network-level blips."""
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise asyncio.TimeoutError()
        return "ok"

    result = asyncio.run(run_with_rate_limit_retry(
        lambda: flaky(),
        phase="test",
        base_delay=0.01,
    ))
    assert result == "ok"
    assert calls["n"] == 2


def test_timeout_not_retried_when_disabled():
    """With retry_timeout=False, asyncio.TimeoutError propagates on first
    occurrence. This is audit's behavior where the timeout is an outer
    operation deadline."""
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        raise asyncio.TimeoutError()

    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(run_with_rate_limit_retry(
            lambda: flaky(),
            phase="test",
            base_delay=0.01,
            retry_timeout=False,
        ))
    assert calls["n"] == 1


def test_non_retryable_error_propagates_immediately():
    """Auth errors and validation errors should never be retried."""
    calls = {"n": 0}

    async def auth_fail():
        calls["n"] += 1
        raise ValueError("401 Unauthorized: invalid api key")

    with pytest.raises(ValueError, match="401"):
        asyncio.run(run_with_rate_limit_retry(
            lambda: auth_fail(),
            phase="test",
            base_delay=0.01,
        ))
    assert calls["n"] == 1


def test_server_suggested_delay_respected():
    """When a 429 carries retry_after, that delay should be used instead
    of exponential backoff."""
    messages: list[str] = []
    calls = {"n": 0}

    async def rate_limited():
        calls["n"] += 1
        if calls["n"] == 1:
            raise ModelHTTPError(
                status_code=429,
                model_name="m",
                body={"retry_after": 0.02},
            )
        return "ok"

    result = asyncio.run(run_with_rate_limit_retry(
        lambda: rate_limited(),
        phase="test",
        base_delay=0.01,
        on_progress=messages.append,
    ))
    assert result == "ok"
    assert any("0.0s" in m for m in messages), messages
