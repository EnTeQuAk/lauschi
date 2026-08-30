"""Tests for is_retryable.

The retry decision gates whether a transient opencode/SDK failure
costs us one slot or burns the whole curation. Classification is by
type at the pydantic-ai boundary: too narrow -> spurious failures, too
broad -> wasted budget on auth errors and doomed replays of validation
failures that will never pass.
"""

from __future__ import annotations

import httpx
import openai
import pytest
from pydantic import ValidationError
from pydantic_ai import ModelHTTPError, UnexpectedModelBehavior
from pydantic_ai.exceptions import UsageLimitExceeded

from lauschi_catalog.retry import describe_failure, is_retryable

# ── Transport types retry ───────────────────────────────────────────────


@pytest.mark.parametrize(
    "make",
    [
        lambda: httpx.ConnectError("refused"),
        lambda: httpx.ReadTimeout("timed out"),
        lambda: httpx.PoolTimeout("pool exhausted"),
        lambda: httpx.RemoteProtocolError("closed without sending a response"),
        lambda: openai.APIConnectionError(request=httpx.Request("GET", "http://x")),
        lambda: openai.InternalServerError(
            "upstream broke", response=httpx.Response(500, request=_req()), body=None
        ),
        lambda: ConnectionError("refused"),
        lambda: TimeoutError("deadline"),
        pytest.param(
            lambda: __import__("requests").exceptions.ConnectionError("reset"),
            id="requests-connection-error",
        ),
    ],
)
def test_transport_types_retry(make):  # noqa: ANN001
    assert is_retryable(make()) is True


def _req():
    return httpx.Request("POST", "http://relay/v1/chat/completions")


# ── HTTP status classification ──────────────────────────────────────────


@pytest.mark.parametrize("status", [500, 502, 503, 504, 429])
def test_model_http_error_with_5xx_and_429_retries(status: int):
    assert (
        is_retryable(
            ModelHTTPError(status_code=status, model_name="m", body={"error": "x"})
        )
        is True
    )


@pytest.mark.parametrize("status", [400, 401, 403, 404])
def test_model_http_error_with_4xx_does_not_retry(status: int):
    assert (
        is_retryable(
            ModelHTTPError(status_code=status, model_name="m", body={"error": "x"})
        )
        is False
    )


def test_httpx_status_error_with_5xx_retries():
    try:
        raise httpx.HTTPStatusError(
            "Server error '503'",
            request=_req(),
            response=httpx.Response(503, request=_req()),
        )
    except httpx.HTTPStatusError as e:
        assert is_retryable(e) is True


# ── Model-own failures never retry, whatever the message says ──────────


def test_validation_error_with_503_in_its_message_is_not_retryable():
    """The regression this module exists for: a curation album said
    'Folge 503 is a box set'. Pydantic embeds the offending input in
    the message, so a string-based 5xx regex saw the 503 and replayed
    a doomed request 12 times with backoff to 300 s. Any validation
    layer classifies the whole failure as model-own."""
    from typing import Literal

    from pydantic import TypeAdapter

    ta = TypeAdapter(Literal["compilation", "wrong_content_type"])
    try:
        ta.validate_python("Folge 503 is a box set")
    except ValidationError as ve:
        assert "503" in str(ve)  # the trap the old string match fell into
        try:
            raise UnexpectedModelBehavior("Exceeded maximum output retries") from ve
        except UnexpectedModelBehavior as exc:
            assert is_retryable(exc) is False


def test_plain_validation_error_retries_never():
    assert is_retryable(ValueError("episode_pattern lacks capture group")) is False


def test_exhausted_output_retries_are_not_retried_by_the_transport_layer():
    assert (
        is_retryable(UnexpectedModelBehavior("Exceeded maximum output retries"))
        is False
    )


def test_usage_limit_exceeded_is_not_retried():
    assert is_retryable(UsageLimitExceeded("request limit of 200 exceeded")) is False


# ── String fallback: only the wrapped-HTML-page case ───────────────────


def test_wrapped_html_error_page_retries():
    """A provider outage answers with an HTML error page wrapped as
    plain text; the doctype is the only reliable marker."""
    assert (
        is_retryable(Exception("<!DOCTYPE html><html><body>502</body></html>")) is True
    )


@pytest.mark.parametrize(
    "msg",
    [
        "HTTP 502 Bad Gateway",
        "Status 503 Service Unavailable",
        "Read timed out (read timeout=600)",
        "Connection reset by peer",
        "Service temporarily unavailable",
    ],
)
def test_lookalike_strings_without_a_type_or_html_do_not_retry(msg: str):
    """Status codes inside free text are no longer a retry signal: the
    real transports carry typed exceptions. A validation message can
    contain anything, including '503'."""
    assert is_retryable(Exception(msg)) is False


# ── Non-retryable cases ────────────────────────────────────────────────


def test_socket_error_does_not_retry():
    assert (
        is_retryable(__import__("socket").gaierror("name resolution failed")) is False
    )


def test_connection_refused_retries():
    assert is_retryable(ConnectionRefusedError("nope")) is True


def test_keyboard_interrupt_subclass_does_not_retry():
    assert is_retryable(Exception("user pressed Ctrl-C")) is False


# ── exception chain walk ──────────────────────────────────────────────


def test_wrapped_connection_error_via_cause_retries():
    """pydantic-ai wraps SDK errors; the underlying transport class
    is reached through __cause__. The check must follow the chain."""
    try:
        raise RuntimeError("agent run failed") from ConnectionError("refused")
    except RuntimeError as e:
        assert is_retryable(e) is True


def test_wrapped_via_implicit_context_retries():
    """Implicit chaining (raise inside an except) sets __context__,
    not __cause__. The walk should follow that too."""
    try:
        try:
            raise ConnectionError("refused")
        except ConnectionError:
            raise RuntimeError("wrapped")
    except RuntimeError as e:
        assert is_retryable(e) is True


def test_model_own_failure_buried_in_a_chain_still_does_not_retry():
    """A transport-looking message inside a validation failure stays
    non-retryable, wherever in the chain the validation layer sits."""
    inner = ValueError("<!doctype html>")
    wrapped = UnexpectedModelBehavior("Exceeded maximum output retries")
    wrapped.__cause__ = inner
    assert is_retryable(wrapped) is False


def test_chain_walk_does_not_loop_on_self_reference():
    a = RuntimeError("a")
    b = RuntimeError("b")
    a.__cause__ = b
    b.__cause__ = a
    assert is_retryable(a) is False


def test_chain_walk_handles_deep_chain():
    deepest: BaseException = ConnectionError("deep")
    cur: BaseException = deepest
    for i in range(6):
        wrapper = RuntimeError(f"layer {i}")
        wrapper.__cause__ = cur
        cur = wrapper
    assert is_retryable(cur) is True


# ── describe_failure walks the whole cause chain ────────────────────────


def test_describe_failure_includes_the_buried_cause():
    try:
        raise RuntimeError("Exceeded maximum output retries (2)") from ValueError(
            "bad output"
        )
    except RuntimeError as exc:
        text = describe_failure(exc)
    assert "RuntimeError: Exceeded maximum output retries (2)" in text
    assert "ValueError: bad output" in text


def test_describe_failure_survives_a_self_referential_chain():
    a: BaseException = RuntimeError("a")
    b: BaseException = RuntimeError("b")
    a.__cause__ = b
    b.__cause__ = a
    assert describe_failure(a)  # terminates, non-empty
