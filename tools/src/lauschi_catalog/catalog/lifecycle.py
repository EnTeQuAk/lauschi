"""Pipeline-step staleness checks.

The catalog flows through curate → review → verify → apply. Each step
writes a timestamp on the curation it produced. Downstream steps must
not act on outputs that have been invalidated by a later upstream
re-run — otherwise a re-curate ships unverified data, or a re-review
gets a verify-stamp from before its actions existed.

This module is the single source of truth for "is the prior pipeline
output still trustworthy?" Pure data-in / bool-out helpers, no I/O,
no side effects. The CLI commands (review, verify, apply) ask these
questions to gate their skip/run/refuse logic.

## Limits of this approach

These checks trust the recorded timestamps to reflect reality. If a
human (or an out-of-band script) edits a curation JSON without
bumping ``curated_at``/``reviewed_at``/``verified_at``, the staleness
checks won't notice — verify and apply will keep happily reusing the
prior verdict. Pipeline tools always bump the relevant timestamp on
write, so this only matters for direct file edits. When you hand-
edit, also clear the downstream timestamps (``review.reviewed_at``
and ``review.verification``) or pass ``--force`` on the next run.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any


def _parse_ts(value: Any) -> datetime | None:
    """Parse an ISO-8601 string into a datetime, or return None.

    All our writers use ``datetime.now(UTC).isoformat()``, which is
    parseable by ``datetime.fromisoformat`` on Python 3.11+. Non-string
    values, empty strings, or malformed timestamps yield None — the
    caller decides what missing means.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def review_is_stale(curation: dict) -> bool:
    """True when curate has run since the last review.

    Conservative on missing data: if either timestamp is absent or
    unparseable, returns False (not stale). Falling back to the
    existing status-based skip is the right call when we can't tell
    — pre-existing curations without ``reviewed_at`` should be
    respected unless the user passes --force.
    """
    curated = _parse_ts(curation.get("curated_at"))
    reviewed = _parse_ts(curation.get("review", {}).get("reviewed_at"))
    if curated is None or reviewed is None:
        return False
    return curated > reviewed


def verification_is_stale(curation: dict) -> bool:
    """True when the prior verification can't be trusted to cover the
    current review.

    More aggressive than ``review_is_stale``: verify is the security
    gate before apply, so we err toward re-running.

    - Missing ``reviewed_at`` (legacy review block, or never reviewed
      with the current schema) → stale; can't verify a review that
      was never timestamped.
    - Missing ``verified_at`` (no verification block, or partial)
      → stale; can't trust a status without a verification record.
    - Both present → stale iff review ran after the last verify.
    """
    review = curation.get("review", {})
    reviewed = _parse_ts(review.get("reviewed_at"))
    verified = _parse_ts(review.get("verification", {}).get("verified_at"))
    if reviewed is None:
        return True
    if verified is None:
        return True
    return reviewed > verified


def apply_is_unsafe(curation: dict) -> str | None:
    """Return a human-readable reason if this curation can't be safely
    applied to series.yaml, or ``None`` if it's safe.

    Apply ships data to the live catalog (and via that, to the app).
    Refusing on staleness is defense in depth: if the user runs
    ``apply --all`` standalone after a re-curate-without-review, this
    catches the silent-stale-data case.
    """
    if review_is_stale(curation):
        return (
            "review is stale (curate ran after last review). "
            "Run review before apply."
        )
    if verification_is_stale(curation):
        return (
            "verification is stale (review changed since last verify, "
            "or verification block is missing). Run verify before apply."
        )
    return None
