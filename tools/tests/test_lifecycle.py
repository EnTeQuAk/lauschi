"""Tests for catalog.lifecycle staleness checks.

These pin the pipeline's source-of-truth for "has an upstream re-run
invalidated this downstream output?" — small functions, big
consequences (skip logic in audit and apply depends on them).
"""

import pytest

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


@pytest.mark.parametrize(
    ("curated_at", "audited_at", "stale"),
    [
        pytest.param(T2, T1, True, id="curate ran after the audit"),
        pytest.param(T1, T2, False, id="audit ran after curate"),
        pytest.param(T1, T1, False, id="same instant"),
        pytest.param(None, T1, False, id="no curated_at"),
        pytest.param(T1, None, False, id="no audited_at (no review block)"),
        pytest.param("not a timestamp", T1, False, id="unparseable curated_at"),
        pytest.param(
            "2026-02-01T00:00:00",
            T3,
            False,
            id="naive curated_at before an aware audit",
        ),
        pytest.param(
            "2026-04-01T00:00:00", T1, True, id="naive curated_at after an aware audit"
        ),
    ],
)
def test_audit_is_stale_only_when_curate_ran_after_the_audit(
    curated_at, audited_at, stale
):
    assert (
        audit_is_stale(_curation(curated_at=curated_at, audited_at=audited_at)) is stale
    )


# ── apply_is_unsafe ───────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("curated_at", "audited_at", "incomplete", "unsafe_because"),
    [
        pytest.param(T1, T2, None, None, id="consistent pipeline output"),
        pytest.param(
            T1, None, None, None, id="never audited: staleness unknown, allowed"
        ),
        pytest.param(T2, T1, None, "audit", id="audit is stale"),
        pytest.param(T1, T2, True, "incomplete", id="curation marked incomplete"),
        pytest.param(T1, T2, False, None, id="explicitly complete"),
    ],
)
def test_apply_is_unsafe_names_the_reason(
    curated_at, audited_at, incomplete, unsafe_because
):
    c = _curation(curated_at=curated_at, audited_at=audited_at)
    if incomplete is not None:
        c["incomplete"] = incomplete
        if incomplete:
            c["incomplete_reason"] = "spotify discovery collapsed: 445 -> 47"
    msg = apply_is_unsafe(c)
    if unsafe_because is None:
        assert msg is None
    else:
        assert msg is not None and unsafe_because in msg.lower()
