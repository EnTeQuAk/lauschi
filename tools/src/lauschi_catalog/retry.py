"""Shared retry-decision helpers used by curate and audit.

Classify at the pydantic-ai boundary: model-own failures (validation
errors, exhausted output retries, usage limits) must die fast and be
handed to the fresh-context layer; transport failures (5xx, 429,
connection errors, timeouts) should replay.
"""

from typing import Iterable

import httpx
import requests
from openai import (
    APIConnectionError,
    APITimeoutError,
    InternalServerError,
)
from pydantic import ValidationError
from pydantic_ai import ModelHTTPError, UnexpectedModelBehavior
from pydantic_ai.exceptions import UsageLimitExceeded

#: Failures the model owns, not the transport. Replaying them just
#: burns budget: a validation error will fail identically on the same
#: prompt. The fresh-context attempt layer is what handles these.
_MODEL_OWN: tuple[type[BaseException], ...] = (
    ValidationError,
    UnexpectedModelBehavior,
    UsageLimitExceeded,
)

#: Transport-class errors worth replaying. Matched by type, not by
#: class *name* so a lookalike exception named "Timeout" does not get
#: retried.
_RETRYABLE_TYPES: tuple[type[BaseException], ...] = (
    httpx.TransportError,  # incl. timeouts, pool exhaustion, read errors
    APIConnectionError,  # openai; APITimeoutError subclasses it
    APITimeoutError,
    InternalServerError,  # openai's 5xx
    requests.exceptions.ConnectionError,
    requests.exceptions.Timeout,
    ConnectionError,  # builtin; covers ConnectionRefusedError etc.
    TimeoutError,  # asyncio.TimeoutError is an alias of this
)


def _status_code(layer: BaseException) -> int | None:
    """HTTP status the layer carries, when it does."""
    if isinstance(layer, ModelHTTPError):
        return layer.status_code
    response = getattr(layer, "response", None)  # httpx / requests errors
    status = getattr(response, "status_code", None)
    return status if isinstance(status, int) else None


def _is_transient_status(status: int | None) -> bool:
    return status is not None and (status >= 500 or status == 429)


def _exception_chain(exc: BaseException) -> Iterable[BaseException]:
    """Yield exc and every linked exception via __cause__/__context__.

    pydantic-ai wraps SDK errors in framework-specific types and
    chains the underlying exception via ``raise X from Y`` (which
    sets __cause__) or implicit chaining (__context__). Walking the
    chain lets us see the original transport-class failure even when
    the outermost type is generic.

    Bounded depth (8) so a pathological chain can't loop forever.
    Cycle-safe via a visited set.
    """
    seen: set[int] = set()
    cur: BaseException | None = exc
    depth = 0
    while cur is not None and id(cur) not in seen and depth < 8:
        seen.add(id(cur))
        yield cur
        cur = cur.__cause__ or cur.__context__
        depth += 1


def is_retryable(exc: BaseException) -> bool:
    """True when the exception suggests a transient upstream failure.

    Two passes on the full exception chain, model-own first:

    1. Any model-own layer (validation error, exhausted output
       retries, usage limits) makes the whole failure non-retryable.
       Classification by string would see the episode number "503"
       inside a validation message and replay a doomed request.
    2. Transport types (httpx/openai/requests connection errors and
       timeouts), real 5xx/429 status codes, and provider HTML error
       pages embedded in a wrapped message are retryable.
    """
    for layer in _exception_chain(exc):
        if isinstance(layer, _MODEL_OWN):
            return False

    for layer in _exception_chain(exc):
        if isinstance(layer, _RETRYABLE_TYPES):
            return True
        if _is_transient_status(_status_code(layer)):
            return True
        # Some providers answer a proxy outage with an HTML error page
        # wrapped as plain text; the doctype is the only reliable marker.
        if "<!doctype" in str(layer).lower():
            return True
    return False


def describe_failure(exc: BaseException) -> str:
    """``Type: message`` for an exception and everything it was raised from.

    pydantic-ai wraps the last validation error in
    ``UnexpectedModelBehavior("Exceeded maximum output retries")`` and
    keeps the reason only on ``__cause__``. A batch that fails for that
    reason is useless to debug without it.
    """
    parts: list[str] = []
    cur: BaseException | None = exc
    for cur in _exception_chain(exc):
        text = str(cur)
        parts.append(f"{type(cur).__name__}: {text}" if text else type(cur).__name__)
    return " <- ".join(parts)
