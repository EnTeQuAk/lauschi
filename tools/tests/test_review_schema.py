"""Tests for the strict ReviewResult schema.

The schema's two contracts:
1. Required per-category decisions (StructuralReview) — pinned by the
   "required field" tests.
2. Cross-field consistency — when an action verdict has an empty action
   list, the validator coerces the verdict to ``DEFERRED`` instead of
   raising. We tried raising; pydantic-ai's inner retries exhausted
   themselves on cases where the model could reason about an action but
   couldn't emit the nested JSON. Coercion preserves the structured
   output, surfaces the inconsistency to humans via the deferred verdict
   and a reasoning suffix, and keeps the discrete-verdict benefits intact.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from lauschi_catalog.commands.review import (
    AddedAlbum,
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
    ReviewOverride,
    ReviewResult,
    SplitProposal,
    StructuralReview,
    SubSeriesDecision,
    SubSeriesVerdict,
)


def _clean() -> StructuralReview:
    """No-action baseline for tests that change one category."""
    r = "test"
    return StructuralReview(
        duplicates=DuplicatesDecision(verdict=DuplicatesVerdict.NONE_FOUND, reasoning=r),
        sub_series=SubSeriesDecision(verdict=SubSeriesVerdict.NONE_FOUND, reasoning=r),
        gaps=GapsDecision(verdict=GapsVerdict.NONE_PRESENT, reasoning=r),
        pattern=PatternDecision(verdict=PatternVerdict.CURRENT_PATTERN_CORRECT, reasoning=r),
        outliers=OutliersDecision(verdict=OutliersVerdict.NONE_FOUND, reasoning=r),
        cross_provider=CrossProviderDecision(verdict=CrossProviderVerdict.BALANCED, reasoning=r),
    )


def _result(**kwargs):
    """Build a ReviewResult with sensible defaults plus overrides."""
    defaults = {
        "decisions": _clean(),
        "summary": "test",
    }
    defaults.update(kwargs)
    return ReviewResult(**defaults)


# ── required fields ───────────────────────────────────────────────────────


def test_review_result_requires_decisions():
    """The whole point of the strict schema: decisions is mandatory."""
    with pytest.raises(ValidationError):
        ReviewResult(summary="hi")


def test_review_result_requires_summary():
    with pytest.raises(ValidationError):
        ReviewResult(decisions=_clean())


def test_review_result_constructible_with_minimum():
    """No-op review with all 'nothing found' verdicts is valid."""
    r = _result()
    assert r.overrides == []
    assert r.decisions.duplicates.verdict == DuplicatesVerdict.NONE_FOUND


# ── verdict literal enforcement ───────────────────────────────────────────


def test_invalid_verdict_rejected():
    """The model can't make up a new verdict string."""
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="unicorn", reasoning="x")


def test_each_decision_has_distinct_verdict_set():
    """Catches the 'all decisions accept the same enum' mistake."""
    # GapsVerdict.VERIFIED_CONTENT_ROTATION is valid for gaps,
    # but isn't a member of DuplicatesVerdict.
    GapsDecision(verdict=GapsVerdict.VERIFIED_CONTENT_ROTATION, reasoning="x")
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="verified_content_rotation", reasoning="x")


# ── cross-field coercion ──────────────────────────────────────────────────


def test_resolved_via_overrides_with_empty_overrides_coerces_to_deferred():
    decisions = _clean()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES,
        reasoning="found two pairs",
    )
    result = _result(decisions=decisions)
    # Coerced: verdict downgraded to DEFERRED
    assert result.decisions.duplicates.verdict == DuplicatesVerdict.DEFERRED
    # Reasoning preserved with a marker so humans can spot the coercion
    assert "auto-downgraded" in result.decisions.duplicates.reasoning


def test_resolved_via_overrides_passes_with_overrides():
    """When the action list is populated, the verdict survives."""
    decisions = _clean()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES, reasoning="x",
    )
    result = _result(
        decisions=decisions,
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
    )
    assert result.decisions.duplicates.verdict == DuplicatesVerdict.RESOLVED_VIA_OVERRIDES
    assert result.overrides[0].album_id == "a"


def test_splits_proposed_with_empty_splits_coerces_to_deferred():
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="found three sub-series",
    )
    result = _result(decisions=decisions)
    assert result.decisions.sub_series.verdict == SubSeriesVerdict.DEFERRED
    assert "auto-downgraded" in result.decisions.sub_series.reasoning


def test_splits_proposed_passes_with_splits():
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="x",
    )
    result = _result(
        decisions=decisions,
        splits=[SplitProposal(
            new_series_id="sub", new_series_title="Sub",
            album_ids=["a"], provider="spotify", reason="x",
        )],
    )
    assert result.decisions.sub_series.verdict == SubSeriesVerdict.SPLITS_PROPOSED


def test_filled_via_add_album_with_empty_added_coerces_to_deferred():
    decisions = _clean()
    decisions.gaps = GapsDecision(
        verdict=GapsVerdict.FILLED_VIA_ADD_ALBUM, reasoning="x",
    )
    result = _result(decisions=decisions)
    assert result.decisions.gaps.verdict == GapsVerdict.DEFERRED


def test_pattern_updated_with_no_pattern_update_coerces_to_deferred():
    decisions = _clean()
    decisions.pattern = PatternDecision(
        verdict=PatternVerdict.PATTERN_UPDATED, reasoning="x",
    )
    result = _result(decisions=decisions)
    assert result.decisions.pattern.verdict == PatternVerdict.DEFERRED


def test_outliers_excluded_via_overrides_with_empty_overrides_coerces_to_deferred():
    decisions = _clean()
    decisions.outliers = OutliersDecision(
        verdict=OutliersVerdict.EXCLUDED_VIA_OVERRIDES, reasoning="x",
    )
    result = _result(decisions=decisions)
    assert result.decisions.outliers.verdict == OutliersVerdict.DEFERRED


def test_no_action_verdicts_dont_get_coerced():
    """The negative case: 'no_X_found' verdicts let action lists stay empty."""
    result = _result()  # baseline: all no_action verdicts, empty action lists
    assert result.decisions.duplicates.verdict == DuplicatesVerdict.NONE_FOUND
    assert result.decisions.sub_series.verdict == SubSeriesVerdict.NONE_FOUND


def test_coercion_is_independent_per_category():
    """Two categories can be coerced at once; consistent ones survive."""
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="x",
    )
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES, reasoning="x",
    )
    # Provide overrides but not splits — duplicates verdict survives,
    # sub_series gets coerced.
    result = _result(
        decisions=decisions,
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
    )
    assert result.decisions.duplicates.verdict == DuplicatesVerdict.RESOLVED_VIA_OVERRIDES
    assert result.decisions.sub_series.verdict == SubSeriesVerdict.DEFERRED


# ── decision reasoning ────────────────────────────────────────────────────


def test_decision_reasoning_is_required():
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict=DuplicatesVerdict.NONE_FOUND)  # type: ignore[call-arg]


def test_strenum_serializes_as_string():
    """Pydantic dumps StrEnum verdicts as plain strings — the on-disk
    JSON shape stays human-readable and stable."""
    result = _result()
    dumped = result.model_dump()
    assert dumped["decisions"]["duplicates"]["verdict"] == "no_within_provider_duplicates"
    assert isinstance(dumped["decisions"]["duplicates"]["verdict"], str)
