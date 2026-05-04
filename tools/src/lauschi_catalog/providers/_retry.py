"""HTTP retry helpers shared across provider implementations.

Both Spotify and Apple Music speak HTTP via the requests library and
both can receive ``Retry-After`` headers in any of the spec's allowed
forms. Keeping the parser here avoids duplicating the float / HTTP-date
handling in each provider — and avoids the foot-gun where one provider
gets a fix that the other doesn't.
"""

from __future__ import annotations

import time
from email.utils import parsedate_to_datetime

_RETRY_AFTER_DEFAULT = 2.0
_RETRY_AFTER_MAX = 60.0


def parse_retry_after(raw: str | None) -> float:
    """Parse a Retry-After header value into seconds.

    The HTTP spec (RFC 7231 §7.1.3) allows two forms: a delta-seconds
    integer, or an HTTP-date. Apple has been observed to send floats
    too (``"1.5"``). All three need to round-trip here without raising
    — a previous ``int(raw)`` crashed on floats and dates and that
    crash propagated up through the request loop.

    Returns the default (2s) on anything unparseable. Caps at 60s so
    a hostile or buggy Retry-After can't stall a provider for minutes
    per call.
    """
    if not raw:
        return _RETRY_AFTER_DEFAULT
    raw = raw.strip()
    try:
        return min(max(float(raw), 0.0), _RETRY_AFTER_MAX)
    except ValueError:
        pass
    try:
        target = parsedate_to_datetime(raw)
        # parsedate_to_datetime returns aware datetime when the header
        # carries a timezone, naive otherwise. Compute remaining seconds
        # from now; clamp negative to 0.
        now = time.time()
        delta = target.timestamp() - now
        return min(max(delta, 0.0), _RETRY_AFTER_MAX)
    except (TypeError, ValueError):
        return _RETRY_AFTER_DEFAULT
