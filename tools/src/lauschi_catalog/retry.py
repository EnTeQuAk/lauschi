"""Shared retry-decision helpers used by curate, review, and verify.

The pipeline's three LLM commands all wrap their agent calls in a
manual retry loop. They need the same answer to "is this exception
worth retrying or should it propagate immediately?" — auth failures
and validation errors should die fast; transport errors and 5xx
should retry.

Keeping this in a single module avoids three copies of the heuristic
drifting apart, and lets review/verify benefit from refinements that
were originally driven by curate's failure modes (mostly opencode
upstream blips).
"""

from __future__ import annotations

import re
from typing import Iterable

# Cloudflare HTML pages, generic transport messages embedded in
# wrapped exceptions. Lower-case match.
_RETRYABLE_PATTERNS: tuple[str, ...] = (
    "<!doctype",
    "timeout",
    "timed out",
    "connection",
    "temporarily unavailable",
)

# Any 5xx or 429 status code embedded in an error string.
_RETRYABLE_STATUS = re.compile(r"\b(?:5\d\d|429)\b")

# Type-name match by string so we don't take an import dependency on
# every SDK's exception namespace. Matched against the full MRO so a
# subclass (e.g. requests.ConnectTimeout < Timeout) still hits.
# Covers requests / urllib3 / httpx / openai SDK — the layers
# pydantic-ai routes through to opencode.
_RETRYABLE_TYPE_NAMES: frozenset[str] = frozenset({
    # requests / urllib3
    "ConnectionError", "ConnectTimeout", "ReadTimeout", "Timeout",
    "SSLError", "ChunkedEncodingError",
    "MaxRetryError", "NewConnectionError", "ProtocolError",
    # httpx
    "ConnectError", "ReadError", "WriteError",
    "PoolTimeout", "RemoteProtocolError",
    # openai SDK
    "APIConnectionError", "APITimeoutError", "InternalServerError",
})


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

    Three-pronged check on the full exception chain:
    1. MRO type-name walk — catches typed transport errors regardless
       of the SDK that raised them.
    2. String pattern match — catches HTML error pages and connection
       signals embedded in wrapped exception messages.
    3. 5xx regex — catches any 5xx status referenced in the message.

    Auth / validation / 4xx errors fall through and propagate;
    retrying them just burns budget.
    """
    for layer in _exception_chain(exc):
        type_names = {cls.__name__ for cls in type(layer).__mro__}
        if type_names & _RETRYABLE_TYPE_NAMES:
            return True
        err_str = str(layer)
        lowered = err_str.lower()
        if any(p in lowered for p in _RETRYABLE_PATTERNS):
            return True
        if _RETRYABLE_STATUS.search(err_str):
            return True
    return False
