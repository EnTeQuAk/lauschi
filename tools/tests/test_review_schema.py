"""Tests for the ReviewResult model itself.

ReviewResult is intentionally minimal: just ``decisions`` and
``summary``. Action proposals (overrides, splits, etc.) flow through
tool calls and merge into AssembledReview at the end of the run, not
through this model. Tests that used to pin cross-field validators now
live in test_assemble_review.py.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from lauschi_catalog.commands.review import (
    CrossProviderDecision,
    CrossProviderVerdict,
    DuplicatesDecision,
    DuplicatesVerdict,
    GapsDecision,
    GapsVerdict,
    OutliersDecision,
    OutliersVerdict,
    PatternDecision,
    PatternVerdict,
    ReviewResult,
    StructuralReview,
    SubSeriesDecision,
    SubSeriesVerdict,
)


def _clean() -> StructuralReview:
    """No-action baseline."""
    r = "test"
    return StructuralReview(
        duplicates=DuplicatesDecision(verdict=DuplicatesVerdict.NONE_FOUND, reasoning=r),
        sub_series=SubSeriesDecision(verdict=SubSeriesVerdict.NONE_FOUND, reasoning=r),
        gaps=GapsDecision(verdict=GapsVerdict.NONE_PRESENT, reasoning=r),
        pattern=PatternDecision(verdict=PatternVerdict.CURRENT_PATTERN_CORRECT, reasoning=r),
        outliers=OutliersDecision(verdict=OutliersVerdict.NONE_FOUND, reasoning=r),
        cross_provider=CrossProviderDecision(verdict=CrossProviderVerdict.BALANCED, reasoning=r),
    )


# ── required fields ───────────────────────────────────────────────────────


def test_review_result_requires_decisions():
    with pytest.raises(ValidationError):
        ReviewResult(summary="hi")


def test_review_result_requires_summary():
    with pytest.raises(ValidationError):
        ReviewResult(decisions=_clean())


def test_review_result_constructible_with_minimum():
    r = ReviewResult(decisions=_clean(), summary="ok")
    assert r.summary == "ok"


def test_review_result_has_no_action_list_fields():
    """The architectural commitment: action lists live on Deps, not here."""
    r = ReviewResult(decisions=_clean(), summary="ok")
    assert not hasattr(r, "overrides")
    assert not hasattr(r, "splits")
    assert not hasattr(r, "added_albums")
    assert not hasattr(r, "pattern_update")


def test_summary_max_length_enforced():
    """Hard cap on summary length forecloses the prose-leak path."""
    with pytest.raises(ValidationError):
        ReviewResult(decisions=_clean(), summary="x" * 501)


# ── verdict literal enforcement ───────────────────────────────────────────


def test_invalid_verdict_rejected():
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="unicorn", reasoning="x")


def test_each_decision_has_distinct_verdict_set():
    GapsDecision(verdict=GapsVerdict.VERIFIED_CONTENT_ROTATION, reasoning="x")
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="verified_content_rotation", reasoning="x")


def test_decision_reasoning_is_required():
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict=DuplicatesVerdict.NONE_FOUND)  # type: ignore[call-arg]


def test_decision_reasoning_max_length_enforced():
    with pytest.raises(ValidationError):
        DuplicatesDecision(
            verdict=DuplicatesVerdict.NONE_FOUND,
            reasoning="x" * 351,
        )


def test_strenum_serializes_as_string():
    """Pydantic dumps StrEnum verdicts as plain strings — JSON shape stays
    human-readable and stable across pydantic versions."""
    r = ReviewResult(decisions=_clean(), summary="ok")
    dumped = r.model_dump()
    assert dumped["decisions"]["duplicates"]["verdict"] == "no_within_provider_duplicates"
    assert isinstance(dumped["decisions"]["duplicates"]["verdict"], str)
