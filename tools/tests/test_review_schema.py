"""Tests for the strict ReviewResult schema.

The schema's two contracts:
1. Required per-category decisions (StructuralReview) — pinned by the
   "required field" tests.
2. Cross-field consistency — when an action verdict has an empty action
   list, the validator coerces the verdict to ``deferred_to_human``
   instead of raising. We tried raising; pydantic-ai's inner retries
   exhausted themselves on cases where the model could reason about an
   action but couldn't emit the nested JSON. Coercion preserves the
   structured output, surfaces the inconsistency to humans via the
   ``deferred_to_human`` verdict and a reasoning suffix, and keeps the
   discrete-verdict benefits intact.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from lauschi_catalog.commands.review import (
    AddedAlbum,
    CrossProviderDecision,
    DuplicatesDecision,
    GapsDecision,
    OutliersDecision,
    PatternDecision,
    ReviewOverride,
    ReviewResult,
    SplitProposal,
    StructuralReview,
    SubSeriesDecision,
)


def _clean() -> StructuralReview:
    """No-action baseline for tests that change one category."""
    r = "test"
    return StructuralReview(
        duplicates=DuplicatesDecision(verdict="no_within_provider_duplicates", reasoning=r),
        sub_series=SubSeriesDecision(verdict="no_sub_series_mixed_in", reasoning=r),
        gaps=GapsDecision(verdict="no_gaps_present", reasoning=r),
        pattern=PatternDecision(verdict="current_pattern_correct", reasoning=r),
        outliers=OutliersDecision(verdict="no_outliers_found", reasoning=r),
        cross_provider=CrossProviderDecision(verdict="balanced", reasoning=r),
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
    assert r.decisions.duplicates.verdict == "no_within_provider_duplicates"


# ── verdict literal enforcement ───────────────────────────────────────────


def test_invalid_verdict_rejected():
    """The model can't make up a new verdict string."""
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="unicorn", reasoning="x")


def test_each_decision_has_distinct_verdict_set():
    """Catches the 'all decisions accept the same literal' mistake."""
    # GapsDecision accepts 'verified_content_rotation', DuplicatesDecision doesn't.
    GapsDecision(verdict="verified_content_rotation", reasoning="x")
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="verified_content_rotation", reasoning="x")


# ── cross-field coercion ──────────────────────────────────────────────────


def test_resolved_via_overrides_with_empty_overrides_coerces_to_deferred():
    decisions = _clean()
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides", reasoning="found two pairs",
    )
    result = _result(decisions=decisions)
    # Coerced: verdict downgraded to deferred_to_human
    assert result.decisions.duplicates.verdict == "deferred_to_human"
    # Reasoning preserved with a marker so humans can spot the coercion
    assert "auto-downgraded" in result.decisions.duplicates.reasoning


def test_resolved_via_overrides_passes_with_overrides():
    """When the action list is populated, the verdict survives."""
    decisions = _clean()
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides", reasoning="x",
    )
    result = _result(
        decisions=decisions,
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
    )
    assert result.decisions.duplicates.verdict == "resolved_via_overrides"
    assert result.overrides[0].album_id == "a"


def test_splits_proposed_with_empty_splits_coerces_to_deferred():
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict="splits_proposed", reasoning="found three sub-series",
    )
    result = _result(decisions=decisions)
    assert result.decisions.sub_series.verdict == "deferred_to_human"
    assert "auto-downgraded" in result.decisions.sub_series.reasoning


def test_splits_proposed_passes_with_splits():
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict="splits_proposed", reasoning="x",
    )
    result = _result(
        decisions=decisions,
        splits=[SplitProposal(
            new_series_id="sub", new_series_title="Sub",
            album_ids=["a"], provider="spotify", reason="x",
        )],
    )
    assert result.decisions.sub_series.verdict == "splits_proposed"


def test_filled_via_add_album_with_empty_added_coerces_to_deferred():
    decisions = _clean()
    decisions.gaps = GapsDecision(verdict="filled_via_add_album", reasoning="x")
    result = _result(decisions=decisions)
    assert result.decisions.gaps.verdict == "deferred_to_human"


def test_pattern_updated_with_no_pattern_update_coerces_to_deferred():
    decisions = _clean()
    decisions.pattern = PatternDecision(verdict="pattern_updated", reasoning="x")
    result = _result(decisions=decisions)
    assert result.decisions.pattern.verdict == "deferred_to_human"


def test_outliers_excluded_via_overrides_with_empty_overrides_coerces_to_deferred():
    decisions = _clean()
    decisions.outliers = OutliersDecision(
        verdict="excluded_via_overrides", reasoning="x",
    )
    result = _result(decisions=decisions)
    assert result.decisions.outliers.verdict == "deferred_to_human"


def test_no_action_verdicts_dont_get_coerced():
    """The negative case: 'no_X_found' verdicts let action lists stay empty."""
    result = _result()  # baseline: all no_action verdicts, empty action lists
    assert result.decisions.duplicates.verdict == "no_within_provider_duplicates"
    assert result.decisions.sub_series.verdict == "no_sub_series_mixed_in"


def test_coercion_is_independent_per_category():
    """Two categories can be coerced at once; consistent ones survive."""
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict="splits_proposed", reasoning="x",
    )
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides", reasoning="x",
    )
    # Provide overrides but not splits — duplicates verdict survives,
    # sub_series gets coerced.
    result = _result(
        decisions=decisions,
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
    )
    assert result.decisions.duplicates.verdict == "resolved_via_overrides"
    assert result.decisions.sub_series.verdict == "deferred_to_human"


# ── decision reasoning ────────────────────────────────────────────────────


def test_decision_reasoning_is_required():
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="no_within_provider_duplicates")  # type: ignore[call-arg]
