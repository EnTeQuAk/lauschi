"""Tests for is_retryable.

The retry decision in _run_with_retry gates whether a transient
opencode/SDK failure costs us one slot or burns the whole curation.
Pinning both prongs of the check (type-by-name and string fallback)
because regressions here are silent: too narrow -> spurious failures,
too broad -> wasted budget on auth errors that won't fix themselves.
"""

from __future__ import annotations

import socket

import pytest

from lauschi_catalog.retry import is_retryable as _is_retryable


# ── Type-by-name (MRO walk) ───────────────────────────────────────────────


def _make(name: str, base: type = Exception, *, msg: str = "") -> Exception:
    """Build a one-off exception class with the requested name and instance."""
    cls = type(name, (base,), {})
    return cls(msg)


@pytest.mark.parametrize("name", [
    "ConnectionError", "ConnectTimeout", "ReadTimeout", "Timeout",
    "SSLError", "ChunkedEncodingError",
    "MaxRetryError", "NewConnectionError", "ProtocolError",
    "ConnectError", "ReadError", "WriteError",
    "PoolTimeout", "RemoteProtocolError",
    "APIConnectionError", "APITimeoutError", "InternalServerError",
])
def test_known_network_type_names_retry(name: str):
    """Each name in _RETRYABLE_TYPE_NAMES must trigger a retry, even
    when the message is empty (some SDK errors set only .response)."""
    assert _is_retryable(_make(name)) is True


def test_subclass_of_known_type_still_retries():
    """The MRO walk catches subclasses too — requests.ConnectTimeout
    inherits from Timeout, both should retry."""
    Timeout = type("Timeout", (Exception,), {})
    ConnectTimeout = type("ConnectTimeout", (Timeout,), {})
    assert _is_retryable(ConnectTimeout()) is True


def test_builtin_connectionerror_retries():
    """Python's built-in ConnectionError shares the name with requests'
    — both go through the same MRO walk."""
    assert _is_retryable(ConnectionError("refused")) is True


def test_socket_error_retries_via_alias():
    """socket.error aliases OSError but its name is still 'OSError';
    real socket-level failures bubble up as ConnectionRefusedError /
    ConnectionResetError, which are subclasses of ConnectionError."""
    assert _is_retryable(socket.gaierror("name resolution failed")) is False
    # but a connection-class subclass does retry
    assert _is_retryable(ConnectionRefusedError("nope")) is True


# ── String fallback ───────────────────────────────────────────────────────


@pytest.mark.parametrize("msg", [
    "<!DOCTYPE html><html><body>502 Bad Gateway</body></html>",
    "HTTP 502 Bad Gateway",
    "Status 503 Service Unavailable",
    "504 Gateway Timeout",
    "Server returned 524",
    "Read timed out (read timeout=600)",
    "Connection reset by peer",
    "Service temporarily unavailable",
])
def test_string_fallback_catches_transient_messages(msg: str):
    assert _is_retryable(Exception(msg)) is True


# ── Non-retryable cases ───────────────────────────────────────────────────


@pytest.mark.parametrize("msg", [
    "401 Unauthorized: invalid api key",
    "AuthenticationError: token expired",
    "ValidationError: 1 validation error for ReviewResult",
    "404 Not Found",
    "400 Bad Request: malformed input",
    "Forbidden: insufficient scope",
])
def test_auth_and_validation_errors_do_not_retry(msg: str):
    """These all need human action — retrying just burns budget."""
    assert _is_retryable(Exception(msg)) is False


def test_plain_value_error_does_not_retry():
    """Generic non-network errors stay non-retryable. The retry layer
    is for transport, not logic."""
    assert _is_retryable(ValueError("episode_pattern lacks capture group")) is False


def test_keyboard_interrupt_subclass_does_not_retry():
    """The retry layer should never resurrect a user-initiated abort."""
    # _is_retryable doesn't see KeyboardInterrupt in normal flow (it
    # bubbles past the except Exception), but the predicate should
    # still answer False if asked.
    assert _is_retryable(Exception("user pressed Ctrl-C")) is False


# ── exception chain walk ──────────────────────────────────────────────────


def test_wrapped_connection_error_via_cause_retries():
    """pydantic-ai wraps SDK errors; the underlying transport class
    is reached through __cause__. The check must follow the chain."""
    underlying = ConnectionError("refused")
    try:
        raise RuntimeError("agent run failed") from underlying
    except RuntimeError as e:
        assert _is_retryable(e) is True


def test_wrapped_via_implicit_context_retries():
    """Implicit chaining (raise inside an except) sets __context__,
    not __cause__. The walk should follow that too."""
    try:
        try:
            raise ConnectionError("refused")
        except ConnectionError:
            raise RuntimeError("wrapped")
    except RuntimeError as e:
        assert _is_retryable(e) is True


def test_chain_walk_does_not_loop_on_self_reference():
    """Pathologically self-referential chains shouldn't hang. The walk
    is bounded and cycle-safe."""
    a = RuntimeError("a")
    b = RuntimeError("b")
    a.__cause__ = b
    b.__cause__ = a
    # Neither has retryable signals; result should be False, not infinite loop.
    assert _is_retryable(a) is False


def test_chain_walk_handles_deep_chain():
    """8-level chain: deepest layer carries the retryable signal.
    Bound is generous enough for real wrapping but caps runaway."""
    deepest = ConnectionError("deep")
    cur: BaseException = deepest
    for i in range(6):
        wrapper = RuntimeError(f"layer {i}")
        wrapper.__cause__ = cur
        cur = wrapper
    assert _is_retryable(cur) is True


def test_chain_walk_outer_layer_alone_decides():
    """Outermost layer with retryable signal still works (no chain needed)."""
    e = ConnectionError("transport")
    assert _is_retryable(e) is True
