"""Small concurrency helpers for catalog fan-outs.

Providers are independent sync requests clients with thread-safe disk
caches, so their sweeps can overlap. Series are the expensive unit (one
LLM interaction each, minutes long); a bounded number of them can run
at once without stepping on opencode-zen's per-model limits.
"""

import asyncio
import inspect
from collections.abc import Awaitable, Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Protocol, TypeVar

In = TypeVar("In")
Out = TypeVar("Out")
T = TypeVar("T")


class NamedProvider(Protocol):
    """The one thing the fan-out needs from a provider."""

    name: str


def map_providers[O](
    fn: Callable[[Any], O],
    providers: Sequence[NamedProvider],
) -> dict[str, O]:
    """Run ``fn(provider)`` concurrently, one worker per provider.

    Returns {provider.name: result}. Exceptions propagate after every
    task completes (fail-loud, no partial-result hiding).
    """
    futures: dict[object, str] = {}
    with ThreadPoolExecutor(max_workers=max(1, len(providers))) as pool:
        for provider in providers:
            futures[pool.submit(fn, provider)] = provider.name
    results: dict[str, O] = {}
    first_error: BaseException | None = None
    for future, name in futures.items():
        try:
            results[name] = future.result()
        except Exception as exc:  # noqa: BLE001
            first_error = first_error or exc
    if first_error is not None:
        raise first_error
    return results


async def run_bounded[In, Out](
    fn: Callable[[In], Awaitable[Out] | Out],
    items: Sequence[In],
    *,
    concurrency: int = 1,
) -> list[Out]:
    """Run ``fn(item)`` for every item, at most ``concurrency`` in
    flight; the result list preserves the input order.

    Series are the expensive unit here (one LLM interaction each).
    Overlapping a couple hides model latency; more copies the load onto
    the relay without data benefit, and its per-model limits are
    unmeasured. Callers opt in explicitly.
    """

    async def run_one(item: In) -> Out:
        result = fn(item)
        if inspect.isawaitable(result):
            return await result
        return result  # type: ignore[return-value]

    if concurrency <= 1:
        return [await run_one(item) for item in items]

    # One semaphore for the whole batch: a per-task semaphore would
    # never bind anything (ruff-visible bug, caught by the peak test).
    slots = asyncio.Semaphore(concurrency)

    async def bounded(item: In) -> Out:
        async with slots:
            return await run_one(item)

    return list(await asyncio.gather(*(bounded(item) for item in items)))
