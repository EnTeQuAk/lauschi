"""Tests for catalog.lifecycle staleness checks.

These pin the pipeline's source-of-truth for "has an upstream re-run
invalidated this downstream output?" — small functions, big
consequences (skip logic at three CLI commands depends on them).
"""

from __future__ import annotations

from lauschi_catalog.catalog.lifecycle import (
    apply_is_unsafe,
    review_is_stale,
    verification_is_stale,
)


def _curation(*, curated_at=None, reviewed_at=None, verified_at=None) -> dict:
    """Build a curation shell with the timestamps we care about set."""
    data: dict = {}
    if curated_at is not None:
        data["curated_at"] = curated_at
    review: dict = {}
    if reviewed_at is not None:
        review["reviewed_at"] = reviewed_at
    if verified_at is not None:
        review["verification"] = {"verified_at": verified_at}
    if review:
        data["review"] = review
    return data


T1 = "2026-01-01T00:00:00+00:00"
T2 = "2026-02-01T00:00:00+00:00"
T3 = "2026-03-01T00:00:00+00:00"


# ── review_is_stale ───────────────────────────────────────────────────────


def test_review_stale_when_curate_ran_after_review():
    c = _curation(curated_at=T2, reviewed_at=T1)
    assert review_is_stale(c) is True


def test_review_not_stale_when_review_ran_after_curate():
    c = _curation(curated_at=T1, reviewed_at=T2)
    assert review_is_stale(c) is False


def test_review_not_stale_when_timestamps_equal():
    """Same instant means review saw the latest curate output."""
    c = _curation(curated_at=T1, reviewed_at=T1)
    assert review_is_stale(c) is False


def test_review_not_stale_with_missing_curated_at():
    """Conservative: can't determine → not stale, fall back to status check."""
    c = _curation(reviewed_at=T1)
    assert review_is_stale(c) is False


def test_review_not_stale_with_missing_reviewed_at():
    """Same conservative call — pre-timestamp legacy reviews are respected."""
    c = _curation(curated_at=T1)
    assert review_is_stale(c) is False


def test_review_not_stale_with_no_review_block():
    """Brand-new curation that hasn't been reviewed yet."""
    c = {"curated_at": T1}
    assert review_is_stale(c) is False


def test_review_not_stale_with_unparseable_timestamps():
    c = _curation(curated_at="not a timestamp", reviewed_at=T1)
    assert review_is_stale(c) is False


# ── verification_is_stale ─────────────────────────────────────────────────


def test_verification_stale_when_review_ran_after_verify():
    c = _curation(curated_at=T1, reviewed_at=T3, verified_at=T2)
    assert verification_is_stale(c) is True


def test_verification_not_stale_when_verify_ran_after_review():
    c = _curation(curated_at=T1, reviewed_at=T1, verified_at=T2)
    assert verification_is_stale(c) is False


def test_verification_stale_when_reviewed_at_missing():
    """Legacy review blocks without a reviewed_at can't be safely verified."""
    c = _curation(curated_at=T1, verified_at=T2)
    assert verification_is_stale(c) is True


def test_verification_stale_when_verified_at_missing():
    """Manual approval with no verification block is treated as needing verify."""
    c = _curation(curated_at=T1, reviewed_at=T1)
    assert verification_is_stale(c) is True


def test_verification_stale_when_both_timestamps_missing():
    c = {"curated_at": T1, "review": {"status": "approved"}}
    assert verification_is_stale(c) is True


def test_verification_not_stale_when_timestamps_equal():
    c = _curation(curated_at=T1, reviewed_at=T1, verified_at=T1)
    assert verification_is_stale(c) is False


# ── apply_is_unsafe ───────────────────────────────────────────────────────


def test_apply_safe_for_consistent_pipeline_output():
    c = _curation(curated_at=T1, reviewed_at=T1, verified_at=T1)
    assert apply_is_unsafe(c) is None


def test_apply_unsafe_when_review_stale():
    c = _curation(curated_at=T2, reviewed_at=T1, verified_at=T1)
    msg = apply_is_unsafe(c)
    assert msg is not None
    assert "review" in msg.lower()


def test_apply_unsafe_when_verification_stale():
    c = _curation(curated_at=T1, reviewed_at=T2, verified_at=T1)
    msg = apply_is_unsafe(c)
    assert msg is not None
    assert "verif" in msg.lower()


def test_apply_unsafe_when_no_verification_block():
    """A status-approved curation with no verification record is unsafe."""
    c = _curation(curated_at=T1, reviewed_at=T1)
    msg = apply_is_unsafe(c)
    assert msg is not None


def test_apply_review_staleness_takes_priority_over_verify_in_message():
    """When both are stale, the message should point at the upstream
    issue first — fixing review will require fixing verify too."""
    c = _curation(curated_at=T3, reviewed_at=T1, verified_at=T2)
    msg = apply_is_unsafe(c)
    assert msg is not None
    assert "review" in msg.lower()
