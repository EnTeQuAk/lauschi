"""Retry orchestration for agent calls with server-hint-aware backoff."""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from typing import Any

from pydantic_ai import ModelHTTPError
from tenacity import (
    AsyncRetrying,
    RetryCallState,
    retry_if_exception,
    stop_after_attempt,
)

from lauschi_catalog.agent_deps import Progress, _noop
from lauschi_catalog.retry import _exception_chain, describe_failure, is_retryable

#: Fresh attempts per agent call before the phase gives up. The audit
#: and curate transports see occasional 502/504 wobbles that outlasted
#: the previous 7 s token-fetch budget, so failures need room to clear.
_MAX_RETRIES = 12
_BASE_DELAY = 10.0
_MAX_DELAY = 300.0


def extract_retry_delay(exc: BaseException) -> float | None:
    """Extract server-suggested retry delay from a 429 error.

    Walks the exception chain for a ModelHTTPError (or a wrapped httpx
    response) with retry_after_ms / retry_after fields. Returns delay in
    seconds, or None if no hint found.
    """
    for layer in _exception_chain(exc):
        if isinstance(layer, ModelHTTPError):
            body = layer.body
            if isinstance(body, dict):
                ms = body.get("retry_after_ms")
                if isinstance(ms, (int, float)) and ms > 0:
                    return ms / 1000.0
                sec = body.get("retry_after")
                if isinstance(sec, (int, float)) and sec > 0:
                    return float(sec)
        response = getattr(layer, "response", None)
        headers = getattr(response, "headers", None)
        if headers is not None and _is_rate_limit(layer):
            try:
                return min(max(float(headers.get("retry-after") or 0), 0.0), 60.0)
            except (TypeError, ValueError):
                pass
    return None


def _is_rate_limit(layer: BaseException) -> bool:
    status = getattr(layer, "status_code", None)
    response = getattr(layer, "response", None)
    code = getattr(response, "status_code", None)
    return (status if isinstance(status, int) else code) == 429


async def run_with_rate_limit_retry(
    coro_factory: Callable[[], Any],
    *,
    phase: str = "",
    max_retries: int = _MAX_RETRIES,
    base_delay: float = _BASE_DELAY,
    max_delay: float = _MAX_DELAY,
    retry_timeout: bool = True,
    on_progress: Progress = _noop,
) -> Any:
    """Run a coroutine with transport-level retry.

    Uses tenacity for retry orchestration with our domain-specific
    retry predicate (is_retryable), server-suggested delay parsing
    from 429 responses.

    Set retry_timeout=False to let asyncio.TimeoutError propagate
    immediately (useful when the timeout is an outer operation
    deadline, not a transient network blip).
    """

    def should_retry(exc: BaseException) -> bool:
        if isinstance(exc, asyncio.TimeoutError):
            return retry_timeout
        return is_retryable(exc)

    def compute_wait(retry_state: RetryCallState) -> float:
        exc = retry_state.outcome.exception() if retry_state.outcome else None
        if exc is not None:
            server_delay = extract_retry_delay(exc)
            if server_delay is not None:
                return min(server_delay, max_delay)
        attempt = retry_state.attempt_number
        return min(base_delay * (2 ** (attempt - 1)), max_delay)

    def log_retry(retry_state: RetryCallState) -> None:
        exc = retry_state.outcome.exception() if retry_state.outcome else None
        if exc is None:
            return
        attempt = retry_state.attempt_number
        wait = retry_state.next_action.sleep  # type: ignore[union-attr]
        if isinstance(exc, asyncio.TimeoutError):
            on_progress(
                f"{phase} attempt {attempt}/{max_retries} "
                f"timed out, retrying in {wait:.1f}s...",
            )
        else:
            on_progress(
                f"{phase} attempt {attempt}/{max_retries} "
                f"failed ({describe_failure(exc)}), "
                f"retrying in {wait:.1f}s...",
            )

    attempt_count = 0
    attempt_count = 0

    try:
        async for attempt in AsyncRetrying(
            retry=retry_if_exception(should_retry),
            stop=stop_after_attempt(max_retries),
            wait=compute_wait,
            before_sleep=log_retry,
            reraise=True,
        ):
            with attempt:
                attempt_count += 1
                return await coro_factory()
    except BaseException as exc:
        if attempt_count >= max_retries:
            if isinstance(exc, asyncio.TimeoutError):
                on_progress(f"{phase} failed: timed out after {max_retries} attempts")
            else:
                on_progress(
                    f"{phase} failed: {describe_failure(exc)[:300]}",
                )
        raise
