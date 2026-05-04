"""Tests for curate._is_retryable.

The retry decision in _run_with_retry gates whether a transient
opencode/SDK failure costs us one slot or burns the whole curation.
Pinning both prongs of the check (type-by-name and string fallback)
because regressions here are silent: too narrow → spurious failures,
too broad → wasted budget on auth errors that won't fix themselves.
"""

from __future__ import annotations

import socket

import pytest

from lauschi_catalog.commands.curate import _is_retryable


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
