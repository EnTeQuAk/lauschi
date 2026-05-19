"""Rate limiting for LLM API calls.

Tracks per-model request timestamps and enforces minimum spacing to
avoid 429 rate-limit errors. Used across curate and audit.
"""

from __future__ import annotations

import asyncio
import json
import time
from dataclasses import dataclass, field
from typing import Any

from lauschi_catalog.retry import is_retryable


# Known rate limits (requests per second) by model provider.
# None means "don't know, use conservative default".
_MIN_SPACING: dict[str, float] = {
    "mistral-small-2603": 1.5,   # 0.83 req/sec free tier → ~1.2s min, add margin
    "mistral-small-2506": 1.5,
    "mistral-large-2512": 1.5,
}
_DEFAULT_MIN_SPACING: float = 0.5  # conservative default for unknown models


@dataclass
class RateLimiter:
    """Token-bucket-ish rate limiter: track last request time, sleep if needed."""

    model_name: str
    _last_request_time: float = field(default_factory=time.monotonic, init=False)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, init=False)

    def _min_spacing(self) -> float:
        """Minimum seconds between requests for this model."""
        # Check prefix match: "mistral-small-2603" → "mistral-small-2603"
        # Also exact match for backward compat.
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
    containing retry_after_ms, retry_after, or similar fields.
    Returns delay in seconds, or None if no hint found.
    """
    from pydantic_ai import ModelHTTPError

    cur: BaseException | None = exc
    depth = 0
    seen: set[int] = set()
    while cur is not None and id(cur) not in seen and depth < 8:
        seen.add(id(cur))
        if isinstance(cur, ModelHTTPError) and cur.status_code == 429:
            body = cur.body
            if isinstance(body, dict):
                # Mistral-style retry_after_ms
                ms = body.get("retry_after_ms")
                if isinstance(ms, (int, float)) and ms > 0:
                    return ms / 1000.0
                # Generic retry_after (seconds)
                sec = body.get("retry_after")
                if isinstance(sec, (int, float)) and sec > 0:
                    return float(sec)
        cur = cur.__cause__ or cur.__context__
        depth += 1
    return None


async def run_with_rate_limit_retry(
    coro_factory,
    *,
    phase: str = "",
    model_name: str = "",
    rate_limiter: RateLimiter | None = None,
    max_retries: int = 5,
    base_delay: float = 5.0,
    max_delay: float = 120.0,
    console=None,
) -> Any:
    """Run a coroutine with rate-limit-aware retry.

    Differences from the old _run_with_retry:
    - Uses a RateLimiter for preemptive spacing between requests
    - Parses server-suggested retry delay from 429 responses
    - More retries (5 instead of 3) with longer, adaptive backoff
    - Exponential backoff with jitter for 429
    """
    last_err: Exception | None = None

    for attempt in range(1, max_retries + 1):
        if rate_limiter is not None:
            await rate_limiter.acquire()

        try:
            return await coro_factory()
        except asyncio.TimeoutError:
            raise
        except Exception as e:
            last_err = e
            if not is_retryable(e):
                raise

            # Extract server-suggested delay, or use exponential backoff
            server_delay = extract_retry_delay(e)
            if server_delay is not None:
                delay = min(server_delay, max_delay)
            else:
                # Exponential backoff: base_delay * 2^(attempt-1) + jitter
                delay = min(base_delay * (2 ** (attempt - 1)), max_delay)
                delay += (hash(phase) % 100) / 1000.0  # small jitter

            if console is not None and attempt < max_retries:
                from rich.markup import escape

                err_str = str(e)
                console.print(
                    f"[yellow]{phase} attempt {attempt}/{max_retries} "
                    f"failed ({type(e).__name__}), "
                    f"retrying in {delay:.1f}s…[/]",
                )
                await asyncio.sleep(delay)
            elif attempt >= max_retries:
                from rich.markup import escape

                console.print(
                    f"[red]{phase} failed: {type(e).__name__}: "
                    f"{escape(str(e)[:300])}[/]",
                )
                raise
            else:
                await asyncio.sleep(delay)

    raise RuntimeError(f"Exhausted {max_retries} retries in {phase}: {last_err}")
