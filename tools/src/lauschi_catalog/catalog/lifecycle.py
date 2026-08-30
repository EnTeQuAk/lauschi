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

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal

from lauschi_catalog.catalog.lint_ops import CRITICAL_PREFIX

CurationStatus = Literal["curated", "approved", "escalated"]


def review_block(curation: dict) -> dict:
    """The audit's review block, or an empty dict when there is none.

    Twelve committed curations carry ``"review": null`` (split-offs
    written before the audit ran). ``curation.get("review", {})``
    returns None for a present-but-null key, and every reader that did
    that crashed on the first such file: a full ``audit`` run and
    ``catalog-apply`` both, reproduced 2026-08-31.
    """
    return curation.get("review") or {}


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
    except ValueError, TypeError:
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
    audited = _parse_ts(review_block(curation).get("audited_at"))
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
    if curation.get("incomplete"):
        reason = curation.get("incomplete_reason", "unknown reason")
        return f"curation is incomplete ({reason}). Fix the curation first."
    if audit_is_stale(curation):
        return "audit is stale (curate ran after last audit). Run audit before apply."
    return None


#: The only review statuses a writer in this repo produces. Audit writes
#: approved and escalated; nothing else exists in the live catalog, so
#: anything else reads as "curated but not yet audited".
CurationStatus = Literal["curated", "approved", "escalated"]


@dataclass(frozen=True)
class Problem:
    """One reason a pipeline step might refuse to touch this curation."""

    kind: str  # incomplete | audit_stale | regression | orphan
    severity: str  # info | warn | critical
    detail: str


@dataclass(frozen=True)
class CurationState:
    """One reading of a curation JSON's pipeline-relevant state.

    from_curation reads today's file keys; nothing about the JSON
    layout changes. Every consumer that used to grep the review dict
    (audit skip logic, apply guards, review-human, the web pipeline)
    reads this instead, so the gates cannot disagree about what the
    file says.
    """

    status: CurationStatus
    problems: tuple[Problem, ...]
    curated_by: str = ""
    curated_at: str | None = None
    audited_at: str | None = None

    @property
    def critical(self) -> tuple[Problem, ...]:
        return tuple(p for p in self.problems if p.severity == "critical")

    @classmethod
    def from_curation(cls, curation: dict | None) -> "CurationState":
        if curation is None:
            return cls(status="curated", problems=())

        status = (curation.get("review") or {}).get("status", "curated")
        normalized: CurationStatus = (
            status if status in ("approved", "escalated") else "curated"
        )

        problems: list[Problem] = []
        if curation.get("incomplete"):
            problems.append(
                Problem(
                    "incomplete",
                    "critical",
                    curation.get("incomplete_reason", "unknown reason"),
                )
            )
        if audit_is_stale(curation):
            problems.append(
                Problem(
                    "audit_stale",
                    "critical",
                    "curate ran after the last audit",
                )
            )
        for flag in curation.get("regression_flags") or []:
            problems.append(
                Problem(
                    "regression",
                    "critical" if flag.startswith(CRITICAL_PREFIX) else "warn",
                    flag,
                )
            )
        if curation.get("orphan_ids"):
            problems.append(
                Problem(
                    "orphan",
                    "warn",
                    f"invented album ids dropped: {', '.join(curation['orphan_ids'])}",
                )
            )

        review = curation.get("review") or {}
        return cls(
            status=normalized,
            problems=tuple(problems),
            curated_by=curation.get("curated_by", ""),
            curated_at=curation.get("curated_at"),
            audited_at=review.get("audited_at"),
        )

    def to_curation(self, curation: dict) -> dict:
        """Write the state's fields back onto the curation dict.

        Mutates and returns ``curation`` (the callers persist the whole
        file; nothing here reads unrelated keys).
        """
        review = curation.get("review") or {}
        review["status"] = self.status
        if self.audited_at:
            review["audited_at"] = self.audited_at
        if review:
            curation["review"] = review
        if self.curated_by:
            curation["curated_by"] = self.curated_by
        if self.curated_at:
            curation["curated_at"] = self.curated_at
        return curation


def needs_audit(state: CurationState) -> bool:
    """True when the audit step should run for a series in this state.

    Approved-and-fresh is the only skip. Anything unrecognizable audits:
    a status no writer produces must not silently skip the 4-eye pass.
    """
    if state.status != "approved":
        return True
    return any(p.kind == "audit_stale" for p in state.problems)


def apply_blockers(
    state: CurationState,
    *,
    allow: set[str] | None = None,
) -> list[str]:
    """Reasons apply refuses this curation, or an empty list when safe.

    One gate for apply (this and the audit skip gate are the pipeline's
    whole honesty story): escalated blocks by name, anything not yet
    approved blocks, and any critical problem - an incomplete run, a
    stale audit, a critical regression - blocks regardless of the
    review status (an approval is necessary, not sufficient). Orphan
    warnings never block: the invented ids were already dropped.
    """
    blockers: list[str] = []
    if state.status == "escalated":
        blockers.append(
            "escalated: audit flagged significant problems; resolve via catalog-review"
        )
    elif state.status != "approved":
        blockers.append("unaudited: run audit before apply")
    for p in state.critical:
        if allow and p.kind in allow:
            continue
        blockers.append(f"{p.kind}: {p.detail}")
    return blockers
