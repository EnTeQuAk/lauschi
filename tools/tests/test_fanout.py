"""Per-provider fan-out runs the providers concurrently.

One network sweep per provider used to be a serial loop although both
providers are independent sync clients (own thread-safe disk cache).
Outputs identical to the sequential loop; wall clock is that of the
slowest provider instead of the sum.
"""

from __future__ import annotations

import threading
import time

import pytest

from lauschi_catalog.fanout import map_providers


class _P:
    def __init__(self, name: str, delay: float = 0.0, fail: bool = False) -> None:
        self.name = name
        self._delay = delay
        self._fail = fail


class TestMapProviders:
    def test_outputs_keyed_by_provider_name_just_like_the_loop(self):
        result = map_providers(lambda p: f"r-{p.name}", [_P("a"), _P("b")])
        assert result == {"a": "r-a", "b": "r-b"}

    def test_slow_providers_overlap(self):
        """With a serial loop 2 x 0.2 s = 0.4 s; concurrently it must be
        close to 0.2 s."""
        providers = [_P("a", delay=0.2), _P("b", delay=0.2)]

        def slow(p):
            time.sleep(p._delay)
            return p.name

        start = time.monotonic()
        map_providers(slow, providers)
        elapsed = time.monotonic() - start
        assert elapsed < 0.35, elapsed  # overlapped, not summed

    def test_tasks_can_block_each_other_without_deadlock(self):
        """Each provider gets its own worker: two simultaneous blocking
        calls must complete, not serialize (the real sweeps block on
        independent HTTP waits)."""
        gate = threading.Barrier(2, timeout=5)
        starts: list[str] = []

        def wait_locked(p):
            starts.append(p.name)
            gate.wait()  # only passes when BOTH providers are inside
            return p.name

        result = map_providers(wait_locked, [_P("a"), _P("b")])
        assert result == {"a": "a", "b": "b"}
        assert sorted(starts) == ["a", "b"]

    def test_failures_propagate_loudly(self):
        def boom(_p):
            raise RuntimeError("provider outage")

        with pytest.raises(RuntimeError, match="outage"):
            map_providers(boom, [_P("a"), _P("b")])

    def test_empty_provider_list_is_an_empty_result(self):
        assert map_providers(lambda p: p.name, []) == {}

    def test_on_failure_caller_discerns_which_provider_failed(self):
        def only_b_fails(p):
            if p.name == "b":
                raise ValueError("b broke")
            return p.name

        with pytest.raises(ValueError, match="b broke"):
            map_providers(only_b_fails, [_P("a"), _P("b")])
