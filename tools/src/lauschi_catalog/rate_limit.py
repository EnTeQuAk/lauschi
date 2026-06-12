"""Rate limiting and retry for LLM API calls.

Tracks per-model request timestamps and enforces minimum spacing to
avoid 429 rate-limit errors. Retry is handled by tenacity with our
domain-specific retry predicate and server-hint-aware backoff.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
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
from lauschi_catalog.retry import is_retryable


# Known rate limits (requests per second) by model provider prefix.
# First match wins. Add entries when a provider's free/paid tier has
# a known ceiling lower than the default.
_MIN_SPACING: dict[str, float] = {}
_DEFAULT_MIN_SPACING: float = 0.5


@dataclass
class RateLimiter:
    """Token-bucket-ish rate limiter: track last request time, sleep if needed."""

    model_name: str
    _last_request_time: float = field(default_factory=time.monotonic, init=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, init=False)

    def _min_spacing(self) -> float:
        """Minimum seconds between requests for this model."""
        for key, spacing in _MIN_SPACING.items():
            if self.model_name.startswith(key):
                return spacing
        return _DEFAULT_MIN_SPACING

    async def acquire(self) -> None:
        """Wait until it's safe to send the next request."""
        async with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_request_time
            spacing = self._min_spacing()
            if elapsed < spacing:
                delay = spacing - elapsed
                await asyncio.sleep(delay)
            self._last_request_time = time.monotonic()


def extract_retry_delay(exc: BaseException) -> float | None:
    """Extract server-suggested retry delay from a 429 error.

    Checks the exception chain for ModelHTTPError with a dict body
    containing retry_after_ms or retry_after fields.
    Returns delay in seconds, or None if no hint found.
    """
    cur: BaseException | None = exc
    depth = 0
    seen: set[int] = set()
    while cur is not None and id(cur) not in seen and depth < 8:
        seen.add(id(cur))
        if isinstance(cur, ModelHTTPError) and cur.status_code == 429:
            body = cur.body
            if isinstance(body, dict):
                ms = body.get("retry_after_ms")
                if isinstance(ms, (int, float)) and ms > 0:
                    return ms / 1000.0
                sec = body.get("retry_after")
                if isinstance(sec, (int, float)) and sec > 0:
                    return float(sec)
        cur = cur.__cause__ or cur.__context__
        depth += 1
    return None


def _error_summary(exc: BaseException) -> str:
    """One-line error description for retry logs.

    Walks the exception chain for a ModelHTTPError so the status code
    and body surface even when the outermost type is a generic
    wrapper; falls back to the stringified exception.
    """
    cur: BaseException | None = exc
    depth = 0
    seen: set[int] = set()
    while cur is not None and id(cur) not in seen and depth < 8:
        seen.add(id(cur))
        if isinstance(cur, ModelHTTPError):
            return f"{type(exc).__name__} {cur.status_code}: {str(cur.body)[:120]}"
        cur = cur.__cause__ or cur.__context__
        depth += 1
    return f"{type(exc).__name__}: {str(exc)[:120]}"


async def run_with_rate_limit_retry(
    coro_factory: Callable[[], Any],
    *,
    phase: str = "",
    rate_limiter: RateLimiter | None = None,
    max_retries: int = 5,
    base_delay: float = 5.0,
    max_delay: float = 120.0,
    retry_timeout: bool = True,
    on_progress: Progress = _noop,
) -> Any:
    """Run a coroutine with rate-limit-aware retry.

    Uses tenacity for retry orchestration with our domain-specific
    retry predicate (is_retryable), server-suggested delay parsing
    from 429 responses, and preemptive rate limiting via RateLimiter.

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
        delay = min(base_delay * (2 ** (attempt - 1)), max_delay)
        delay += (hash(phase) % 100) / 1000.0
        return delay

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
                f"failed ({_error_summary(exc)}), "
                f"retrying in {wait:.1f}s...",
            )

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
                if rate_limiter is not None:
                    await rate_limiter.acquire()
                return await coro_factory()
    except BaseException:
        if attempt_count >= max_retries:
            exc = attempt.retry_state.outcome.exception()  # type: ignore[union-attr]
            if isinstance(exc, asyncio.TimeoutError):
                on_progress(f"{phase} failed: timed out after {max_retries} attempts")
            elif exc is not None:
                err_str = str(exc)[:300]
                on_progress(
                    f"{phase} failed: {type(exc).__name__}: {err_str}",
                )
        raise

    raise RuntimeError(f"Exhausted {max_retries} retries in {phase}")
