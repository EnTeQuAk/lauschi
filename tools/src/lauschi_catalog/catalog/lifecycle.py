"""Pipeline-step staleness checks.

The catalog flows through curate → audit → apply. Each step writes a
timestamp on the curation it produced. The apply step must not ship
data that hasn't been verified by audit since the last curate.

curate clears the entire ``review`` block when it writes, so audit
always runs on freshly-curated series (no review.status → not skipped).
The ``audit_is_stale`` check is defense-in-depth for apply: it catches
the edge case where ``review.audited_at`` wasn't cleared properly.

Timestamps:
- ``curated_at`` (top-level): set by curate on each run.
- ``review.audited_at``: set by audit (the 4-eye pass).

If a human edits a curation JSON without bumping ``curated_at``,
the staleness checks won't notice. When you hand-edit, remove the
``review`` block or pass ``--force`` on the next audit run.
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
