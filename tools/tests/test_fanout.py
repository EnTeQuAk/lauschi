"""Bounded-concurrency runner for the per-series LLM work.

audit_series and curate_all used to run series strictly one after
another; each is one LLM interaction of several seconds to minutes, so
overlapping two hides latency without leaning on unknown relay limits.
The runner must preserve the input order in its results and never
exceed the bound.
"""

from __future__ import annotations

import asyncio

import pytest

from lauschi_catalog.fanout import run_bounded

pytestmark = pytest.mark.anyio


class TestRunBounded:
    async def test_results_preserve_input_order(self):
        async def double(x: int) -> int:
            return x * 2

        assert await run_bounded(double, [1, 2, 3]) == [2, 4, 6]

    async def test_slower_items_stay_in_order(self):
        """A fast item finishing before a slow earlier one must not
        reorder the output (gather with a per-slot task, not a set)."""

        async def vary(i: int) -> int:
            if i == 0:
                await asyncio.sleep(0.03)
            return i

        assert await run_bounded(vary, [0, 1, 2], concurrency=3) == [0, 1, 2]

    async def test_never_exceeds_the_concurrency_bound(self):
        in_flight = 0
        peak = 0

        async def work(i: int) -> int:
            nonlocal in_flight, peak
            in_flight += 1
            peak = max(peak, in_flight)
            await asyncio.sleep(0.01)
            in_flight -= 1
            return i

        got = await run_bounded(work, list(range(8)), concurrency=2)
        assert got == list(range(8))
        assert peak == 2

    async def test_concurrency_one_is_strictly_sequential(self):
        log: list[str] = []

        async def step(i: int) -> str:
            log.append(f"start {i}")
            await asyncio.sleep(0.001)
            log.append(f"end {i}")
            return str(i)

        got = await run_bounded(step, [1, 2], concurrency=1)
        assert got == ["1", "2"]
        assert log == ["start 1", "end 1", "start 2", "end 2"]

    async def test_exceptions_propagate_immediately(self):
        """A raising item propagates out of gather; per-series callers
        catch it themselves. The hang-prone item never gets a slot."""
        started: list[int] = []

        async def fail(i: int) -> int:
            started.append(i)
            if i == 0:
                raise RuntimeError("model died")
            await asyncio.sleep(30)
            return i

        with pytest.raises(RuntimeError, match="model died"):
            await run_bounded(fail, [0, 1, 2], concurrency=1)
        assert started[0] == 0

    async def test_plain_values_are_accepted(self):
        """A stub can return a plain value; the runner must not care."""

        def sync_fn(i: int) -> int:
            return i + 1

        assert await run_bounded(sync_fn, [1, 2]) == [2, 3]

    async def test_empty_items_is_an_empty_list(self):
        async def work(i: int) -> int:
            return i

        assert await run_bounded(work, []) == []
