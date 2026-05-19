"""Tests for catalog.lifecycle staleness checks.

These pin the pipeline's source-of-truth for "has an upstream re-run
invalidated this downstream output?" — small functions, big
consequences (skip logic in audit and apply depends on them).
"""

from __future__ import annotations

from lauschi_catalog.catalog.lifecycle import (
    apply_is_unsafe,
    audit_is_stale,
)


def _curation(*, curated_at=None, audited_at=None) -> dict:
    """Build a curation shell with the timestamps we care about set."""
    data: dict = {}
    if curated_at is not None:
        data["curated_at"] = curated_at
    if audited_at is not None:
        data["review"] = {"audited_at": audited_at}
    return data


T1 = "2026-01-01T00:00:00+00:00"
T2 = "2026-02-01T00:00:00+00:00"
T3 = "2026-03-01T00:00:00+00:00"


# ── audit_is_stale ────────────────────────────────────────────────────────


def test_audit_stale_when_curate_ran_after_audit():
    c = _curation(curated_at=T2, audited_at=T1)
    assert audit_is_stale(c) is True


def test_audit_not_stale_when_audit_ran_after_curate():
    c = _curation(curated_at=T1, audited_at=T2)
    assert audit_is_stale(c) is False


def test_audit_not_stale_when_timestamps_equal():
    c = _curation(curated_at=T1, audited_at=T1)
    assert audit_is_stale(c) is False


def test_audit_not_stale_with_missing_curated_at():
    c = _curation(audited_at=T1)
    assert audit_is_stale(c) is False


def test_audit_not_stale_with_missing_audited_at():
    c = _curation(curated_at=T1)
    assert audit_is_stale(c) is False


def test_audit_not_stale_with_no_review_block():
    c = {"curated_at": T1}
    assert audit_is_stale(c) is False


def test_audit_not_stale_with_unparseable_timestamps():
    c = _curation(curated_at="not a timestamp", audited_at=T1)
    assert audit_is_stale(c) is False


def test_audit_handles_naive_curated_at_without_crashing():
    naive_curated = "2026-02-01T00:00:00"
    aware_audited = T3
    c = _curation(curated_at=naive_curated, audited_at=aware_audited)
    assert audit_is_stale(c) is False


def test_audit_stale_with_naive_curated_after_aware_audit():
    c = _curation(curated_at="2026-04-01T00:00:00", audited_at=T1)
    assert audit_is_stale(c) is True


# ── apply_is_unsafe ───────────────────────────────────────────────────────


def test_apply_safe_for_consistent_pipeline_output():
    c = _curation(curated_at=T1, audited_at=T2)
    assert apply_is_unsafe(c) is None


def test_apply_safe_when_never_audited():
    """No audit timestamp means we can't determine staleness, so
    apply_is_unsafe is conservative and allows it."""
    c = _curation(curated_at=T1)
    assert apply_is_unsafe(c) is None


def test_apply_unsafe_when_audit_stale():
    c = _curation(curated_at=T2, audited_at=T1)
    msg = apply_is_unsafe(c)
    assert msg is not None
    assert "audit" in msg.lower()
