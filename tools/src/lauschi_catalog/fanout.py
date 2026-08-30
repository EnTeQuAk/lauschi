"""Small concurrency helper for catalog fan-outs.

Per-provider work inside one series used to be strictly sequential
while the providers are independent sync requests clients with their
own thread-safe disk caches. One helper runs them in parallel and
keeps the outputs identical to the sequential version; progress may
interleave, which is fine for humans.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Protocol, TypeVar

T = TypeVar("T")


class NamedProvider(Protocol):
    """The one thing the fan-out needs from a provider."""

    name: str


def map_providers(
    fn: Callable[[Any], T],
    providers: Iterable[NamedProvider],
) -> dict[str, T]:
    """Run ``fn(provider)`` concurrently, one worker per provider.

    Returns {provider.name: result}. Exceptions propagate after every
    task completes (fail-loud, no partial-result hiding).
    """
    futures: dict = {}
    with ThreadPoolExecutor(max_workers=max(1, sum(1 for _ in providers))) as pool:
        for provider in providers:
            futures[pool.submit(fn, provider)] = provider.name
    results: dict[str, T] = {}
    first_error: BaseException | None = None
    for future, name in futures.items():
        try:
            results[name] = future.result()
        except Exception as exc:  # noqa: BLE001
            first_error = first_error or exc
    if first_error is not None:
        raise first_error
    return results
