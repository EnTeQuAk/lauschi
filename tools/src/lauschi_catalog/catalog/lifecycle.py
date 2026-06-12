"""Pipeline-step staleness checks.

The catalog flows through curate → audit → apply. Each step writes a
timestamp on the curation it produced. Downstream steps must not act
on outputs that have been invalidated by a later upstream re-run.

This module is the single source of truth for "is the prior pipeline
output still trustworthy?" Pure data-in / bool-out helpers, no I/O,
no side effects. The CLI commands (audit, apply) ask these questions
to gate their skip/run/refuse logic.

Timestamps:
- ``curated_at`` (top-level): set by curate on each run.
- ``review.audited_at``: set by audit (the 4-eye pass).

If a human edits a curation JSON without bumping ``curated_at``,
the staleness checks won't notice. When you hand-edit, also clear
``review.audited_at`` or pass ``--force`` on the next run.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any


def _parse_ts(value: Any) -> datetime | None:
    """Parse an ISO-8601 string into a tz-aware datetime, or return None.

    Naive datetimes (no offset) are normalized to UTC so comparisons
    against the tz-aware timestamps produced by our writers don't
    raise TypeError.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value)
    except (ValueError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def audit_is_stale(curation: dict) -> bool:
    """True when curate has run since the last audit.

    Conservative on missing data: if either timestamp is absent or
    unparseable, returns False (not stale). Pre-existing curations
    without ``audited_at`` should be respected unless the user
    passes --force.
    """
    curated = _parse_ts(curation.get("curated_at"))
    audited = _parse_ts(curation.get("review", {}).get("audited_at"))
    if curated is None or audited is None:
        return False
    return curated > audited


# Keep old name as alias so audit.py's existing import works.
review_is_stale = audit_is_stale


def apply_is_unsafe(curation: dict) -> str | None:
    """Return a human-readable reason if this curation can't be safely
    applied to series.yaml, or ``None`` if it's safe.

    Apply ships data to the live catalog (and via that, to the app).
    Refusing on staleness is defense in depth: if the user runs
    ``apply --all`` standalone after a re-curate-without-audit, this
    catches the silent-stale-data case.
    """
    if audit_is_stale(curation):
        return "audit is stale (curate ran after last audit). Run audit before apply."
    return None
