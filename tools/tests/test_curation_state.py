"""Tests for CurationState: one reading of the curation's pipeline state.

Every reader used to disagree about which review statuses existed and
which gates blocked which step. This pins the three real statuses and
the gate tables both steps must follow.
"""

import pytest

from lauschi_catalog.catalog.lifecycle import (
    CurationState,
    apply_blockers,
    needs_audit,
)


def _curation(**kw) -> dict:
    return kw


# ── status reading ────────────────────────────────────────────────────────


class TestStatusReading:
    def test_approved_reads_as_approved(self):
        state = CurationState.from_curation({"review": {"status": "approved"}})
        assert state.status == "approved"

    def test_escalated_reads_as_escalated(self):
        state = CurationState.from_curation({"review": {"status": "escalated"}})
        assert state.status == "escalated"

    @pytest.mark.parametrize(
        "curation",
        [
            None,
            {},
            {"review": None},  # twelve committed files carry the null
            {"review": {}},
            {"review": {"status": ""}},
            {"review": {"status": "curated"}},
        ],
    )
    def test_missing_or_explicit_curated_reads_as_curated(self, curation):
        assert CurationState.from_curation(curation).status == "curated"

    @pytest.mark.parametrize(
        "ghost",
        [
            "audited",
            "ai_verified",
            "ai_reviewed",
            "approved_with_flags",
            "flagged",
            "rejected",
        ],
    )
    def test_unrecognized_statuses_read_as_curated(self, ghost):
        """Statuses no writer produces must not skip the audit or pass
        apply: they read as 'needs auditing'."""
        state = CurationState.from_curation({"review": {"status": ghost}})
        assert state.status == "curated"

    def test_provenance_is_read_from_the_file_keys(self):
        curation = {
            "curated_by": "kimi-k2.6",
            "curated_at": "2026-08-30T10:00:00+00:00",
            "review": {"audited_at": "2026-08-31T10:00:00+00:00"},
        }
        state = CurationState.from_curation(curation)
        assert state.curated_by == "kimi-k2.6"
        assert state.curated_at == "2026-08-30T10:00:00+00:00"
        assert state.audited_at == "2026-08-31T10:00:00+00:00"


# ── problems ──────────────────────────────────────────────────────────────


class TestProblems:
    def test_incomplete_run_is_critical(self):
        state = CurationState.from_curation(
            {"incomplete": True, "incomplete_reason": "batch 3/7 failed"}
        )
        (problem,) = state.critical
        assert problem.kind == "incomplete"
        assert "batch 3/7" in problem.detail

    def test_stale_audit_is_critical(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-02-01T00:00:00+00:00",
                "review": {"audited_at": "2026-01-01T00:00:00+00:00"},
            }
        )
        kinds = {p.kind for p in state.critical}
        assert "audit_stale" in kinds

    def test_regression_flags_split_by_severity(self):
        state = CurationState.from_curation(
            {
                "regression_flags": [
                    "CRITICAL: Include collapse: 0 included",
                    "info-ish drift note",
                ]
            }
        )
        assert {p.kind for p in state.critical} == {"regression"}
        assert {p.severity for p in state.problems} == {"critical", "warn"}

    def test_orphans_are_a_warning_not_a_blocker(self):
        state = CurationState.from_curation({"orphan_ids": ["spotify:x1"]})
        assert state.critical == ()
        assert state.problems[0].kind == "orphan"
        assert state.problems[0].severity == "warn"

    def test_clean_curation_has_no_problems(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-08-30T10:00:00+00:00",
                "review": {"status": "approved"},
            }
        )
        assert state.problems == ()


# ── round trip: from_curation preserves what apply and audit read ────────


class TestRoundTrip:
    def test_to_curation_rewrites_what_from_curation_read(self):
        curation = {
            "incomplete": True,
            "incomplete_reason": "batch 2 failed",
            "orphan_ids": ["spotify:x"],
            "regression_flags": ["CRITICAL: bad"],
            "curated_by": "m",
            "curated_at": "2026-08-30T10:00:00+00:00",
            "review": {
                "status": "escalated",
                "audited_at": "2026-08-31T10:00:00+00:00",
            },
        }
        state = CurationState.from_curation(curation)
        same = CurationState.from_curation(state.to_curation(curation))
        assert (state.status, state.curated_at, state.audited_at) == (
            same.status,
            same.curated_at,
            same.audited_at,
        )
        assert {p.kind for p in state.problems} >= set()  # noqa: C408
        assert same.to_curation(curation) == state.to_curation(curation)

    def test_to_curation_does_not_touch_unrelated_keys(self):
        curation = {"id": "s", "albums": [{"album_id": "a"}], "review": {}}
        out = CurationState.from_curation(curation).to_curation(curation)
        assert out["id"] == "s"
        assert out["albums"] == curation["albums"]


# ── gate tables ───────────────────────────────────────────────────────────


class TestNeedsAudit:
    """Audit skips a series when it is approved and not stale."""

    @pytest.mark.parametrize(
        ("curation", "expected"),
        [
            ({"review": {"status": "approved"}}, False),
            ({"review": {"status": "escalated"}}, True),
            ({}, True),
            ({"review": None}, True),
            ({"review": {"status": "curated"}}, True),
        ],
    )
    def test_table(self, curation, expected):
        state = CurationState.from_curation(curation)
        assert needs_audit(state) is expected

    def test_reapprove_after_recurate(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-02-01T00:00:00+00:00",
                "review": {
                    "status": "approved",
                    "audited_at": "2026-01-01T00:00:00+00:00",
                },
            }
        )
        assert needs_audit(state) is True


class TestApplyBlockers:
    def test_approved_and_fresh_applies(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-01-01T00:00:00+00:00",
                "review": {
                    "status": "approved",
                    "audited_at": "2026-02-01T00:00:00+00:00",
                },
            }
        )
        assert apply_blockers(state) == []

    def test_escalated_is_blocked_by_name(self):
        state = CurationState.from_curation({"review": {"status": "escalated"}})
        assert "escalated" in [b.split(":")[0] for b in apply_blockers(state)]

    def test_not_audited_is_blocked(self):
        state = CurationState.from_curation({})
        reasons = " ".join(apply_blockers(state))
        assert "audit" in reasons

    def test_any_critical_problem_blocks_apply(self):
        state = CurationState.from_curation(
            {
                "incomplete": True,
                "incomplete_reason": "batch 3/7 failed",
                "curated_at": "2026-01-01T00:00:00+00:00",
                "review": {
                    "status": "approved",
                    "audited_at": "2026-02-01T00:00:00+00:00",
                },
            }
        )
        reasons = apply_blockers(state)
        assert any("incomplete" in r for r in reasons)

    def test_regression_critical_blocks_even_when_approved(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-01-01T00:00:00+00:00",
                "regression_flags": ["CRITICAL: Include collapse"],
                "review": {
                    "status": "approved",
                    "audited_at": "2026-02-01T00:00:00+00:00",
                },
            }
        )
        reasons = " ".join(apply_blockers(state))
        assert "regression" in reasons

    def test_orphans_never_block(self):
        state = CurationState.from_curation(
            {
                "orphan_ids": ["spotify:x"],
                "curated_at": "2026-01-01T00:00:00+00:00",
                "review": {
                    "status": "approved",
                    "audited_at": "2026-02-01T00:00:00+00:00",
                },
            }
        )
        assert apply_blockers(state) == []

    def test_allow_downgrades_specific_blockers(self):
        state = CurationState.from_curation(
            {
                "curated_at": "2026-01-01T00:00:00+00:00",
                "regression_flags": ["CRITICAL: Include collapse"],
                "review": {
                    "status": "approved",
                    "audited_at": "2026-02-01T00:00:00+00:00",
                },
            }
        )
        assert apply_blockers(state, allow={"regression"}) == []
