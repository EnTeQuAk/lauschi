"""Tests for the strict ReviewResult schema.

The cross-field validators are the heart of the strict-contract design:
they make 'I said I'd act, but I forgot to fill the action list' a
pydantic ValidationError that pydantic-ai retries on. These tests pin
that contract.
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


# ── cross-field validators ────────────────────────────────────────────────


def test_resolved_via_overrides_requires_overrides_populated():
    decisions = _clean()
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides", reasoning="x",
    )
    with pytest.raises(ValidationError, match="resolved_via_overrides"):
        _result(decisions=decisions)


def test_resolved_via_overrides_passes_with_overrides():
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
    assert result.overrides[0].album_id == "a"


def test_splits_proposed_requires_splits_populated():
    decisions = _clean()
    decisions.sub_series = SubSeriesDecision(
        verdict="splits_proposed", reasoning="x",
    )
    with pytest.raises(ValidationError, match="splits_proposed"):
        _result(decisions=decisions)


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
    assert result.splits[0].new_series_id == "sub"


def test_filled_via_add_album_requires_added_albums_populated():
    decisions = _clean()
    decisions.gaps = GapsDecision(verdict="filled_via_add_album", reasoning="x")
    with pytest.raises(ValidationError, match="filled_via_add_album"):
        _result(decisions=decisions)


def test_filled_via_add_album_passes_with_added_albums():
    decisions = _clean()
    decisions.gaps = GapsDecision(verdict="filled_via_add_album", reasoning="x")
    result = _result(
        decisions=decisions,
        added_albums=[AddedAlbum(
            album_id="a", provider="spotify", title="t",
            episode_num=1, evidence_url="https://hoerspiele.de/x",
        )],
    )
    assert result.added_albums[0].album_id == "a"


def test_pattern_updated_requires_pattern_update_set():
    decisions = _clean()
    decisions.pattern = PatternDecision(verdict="pattern_updated", reasoning="x")
    with pytest.raises(ValidationError, match="pattern_updated"):
        _result(decisions=decisions)


def test_pattern_updated_passes_with_pattern_update():
    decisions = _clean()
    decisions.pattern = PatternDecision(verdict="pattern_updated", reasoning="x")
    result = _result(decisions=decisions, pattern_update=r"^(\d+):")
    assert result.pattern_update == r"^(\d+):"


def test_outliers_excluded_via_overrides_requires_overrides_populated():
    decisions = _clean()
    decisions.outliers = OutliersDecision(
        verdict="excluded_via_overrides", reasoning="x",
    )
    with pytest.raises(ValidationError, match="excluded_via_overrides"):
        _result(decisions=decisions)


def test_no_action_verdicts_dont_require_lists():
    """The negative case: 'no_X_found' verdicts let action lists stay empty."""
    # Default _clean() already uses no_action verdicts; should construct.
    result = _result()
    assert result.overrides == [] and result.splits == []


# ── decision reasoning ────────────────────────────────────────────────────


def test_decision_reasoning_is_required():
    with pytest.raises(ValidationError):
        DuplicatesDecision(verdict="no_within_provider_duplicates")  # type: ignore[call-arg]
