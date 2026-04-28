"""Tests for review.assemble_review and split-chunk merging.

assemble_review is where coercion + chunk merging now live. It takes
the model's structured output (decisions + summary) and the deps
state populated by tool calls, and returns the AssembledReview that
save_review writes.
"""

from __future__ import annotations

from lauschi_catalog.commands.review import (
    AddedAlbum,
    AssembledReview,
    CrossProviderDecision,
    CrossProviderVerdict,
    Deps,
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
    _merge_split_chunks,
    assemble_review,
)


def _clean_decisions() -> StructuralReview:
    r = "test"
    return StructuralReview(
        duplicates=DuplicatesDecision(verdict=DuplicatesVerdict.NONE_FOUND, reasoning=r),
        sub_series=SubSeriesDecision(verdict=SubSeriesVerdict.NONE_FOUND, reasoning=r),
        gaps=GapsDecision(verdict=GapsVerdict.NONE_PRESENT, reasoning=r),
        pattern=PatternDecision(verdict=PatternVerdict.CURRENT_PATTERN_CORRECT, reasoning=r),
        outliers=OutliersDecision(verdict=OutliersVerdict.NONE_FOUND, reasoning=r),
        cross_provider=CrossProviderDecision(verdict=CrossProviderVerdict.BALANCED, reasoning=r),
    )


def _result(decisions: StructuralReview | None = None, summary: str = "test"):
    return ReviewResult(decisions=decisions or _clean_decisions(), summary=summary)


def _empty_deps() -> Deps:
    return Deps(providers=[], curation={"albums": []})


# ── chunk merging ─────────────────────────────────────────────────────────


def test_merge_chunks_keeps_distinct_split_ids_separate():
    chunks = [
        {"new_series_id": "a", "new_series_title": "A",
         "album_ids": ["x"], "provider": "spotify", "reason": "ra"},
        {"new_series_id": "b", "new_series_title": "B",
         "album_ids": ["y"], "provider": "spotify", "reason": "rb"},
    ]
    merged = _merge_split_chunks(chunks)
    assert len(merged) == 2
    assert {m.new_series_id for m in merged} == {"a", "b"}


def test_merge_chunks_concatenates_album_ids_with_same_split_id():
    """The whole point: agent can chunk a 50-album list across calls."""
    chunks = [
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["a", "b"], "provider": "spotify", "reason": "first"},
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["c", "d"], "provider": "spotify", "reason": "second"},
    ]
    merged = _merge_split_chunks(chunks)
    assert len(merged) == 1
    assert merged[0].album_ids == ["a", "b", "c", "d"]
    # First reason wins
    assert merged[0].reason == "first"


def test_merge_chunks_dedupes_overlapping_album_ids():
    chunks = [
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["a", "b"], "provider": "spotify", "reason": "x"},
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["b", "c"], "provider": "spotify", "reason": "y"},
    ]
    merged = _merge_split_chunks(chunks)
    assert merged[0].album_ids == ["a", "b", "c"]


# ── assemble_review: action propagation ───────────────────────────────────


def test_assembles_with_no_proposals():
    review = assemble_review(_result(), _empty_deps())
    assert review.overrides == []
    assert review.splits == []
    assert review.added_albums == []
    assert review.pattern_update is None


def test_assembles_overrides_from_deps():
    deps = _empty_deps()
    deps.proposed_overrides.append({
        "album_id": "a", "provider": "spotify",
        "action": "exclude", "reason": "duplicate",
    })
    review = assemble_review(_result(), deps)
    assert len(review.overrides) == 1
    assert review.overrides[0].album_id == "a"


def test_assembles_splits_from_deps_with_chunk_merging():
    deps = _empty_deps()
    deps.proposed_splits.extend([
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["a", "b"], "provider": "spotify", "reason": "x"},
        {"new_series_id": "sub", "new_series_title": "Sub",
         "album_ids": ["c"], "provider": "spotify", "reason": "y"},
    ])
    review = assemble_review(_result(), deps)
    assert len(review.splits) == 1
    assert review.splits[0].album_ids == ["a", "b", "c"]


def test_assembles_added_albums_from_deps():
    deps = _empty_deps()
    deps.added_albums.append({
        "album_id": "a", "provider": "spotify", "title": "Folge 1: A",
        "include": True, "episode_num": 1, "exclude_reason": None,
        "evidence_url": "https://hoerspiele.de/x",
    })
    review = assemble_review(_result(), deps)
    assert len(review.added_albums) == 1
    assert review.added_albums[0].evidence_url == "https://hoerspiele.de/x"


def test_assembles_pattern_update_from_deps():
    deps = _empty_deps()
    deps.proposed_pattern_update = r"^Folge (\d+):"
    review = assemble_review(_result(), deps)
    assert review.pattern_update == r"^Folge (\d+):"


# ── assemble_review: coercion ─────────────────────────────────────────────


def test_resolved_via_overrides_with_empty_overrides_coerces():
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES,
        reasoning="found two pairs",
    )
    review = assemble_review(_result(decisions), _empty_deps())
    assert review.decisions.duplicates.verdict == DuplicatesVerdict.DEFERRED
    assert "auto-downgraded" in review.decisions.duplicates.reasoning


def test_resolved_via_overrides_passes_with_overrides_in_deps():
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES, reasoning="x",
    )
    deps = _empty_deps()
    deps.proposed_overrides.append({
        "album_id": "a", "provider": "spotify",
        "action": "exclude", "reason": "x",
    })
    review = assemble_review(_result(decisions), deps)
    assert review.decisions.duplicates.verdict == DuplicatesVerdict.RESOLVED_VIA_OVERRIDES
    assert len(review.overrides) == 1


def test_splits_proposed_with_empty_splits_coerces():
    decisions = _clean_decisions()
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="found three",
    )
    review = assemble_review(_result(decisions), _empty_deps())
    assert review.decisions.sub_series.verdict == SubSeriesVerdict.DEFERRED


def test_splits_proposed_passes_with_splits_in_deps():
    decisions = _clean_decisions()
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="x",
    )
    deps = _empty_deps()
    deps.proposed_splits.append({
        "new_series_id": "sub", "new_series_title": "Sub",
        "album_ids": ["a"], "provider": "spotify", "reason": "x",
    })
    review = assemble_review(_result(decisions), deps)
    assert review.decisions.sub_series.verdict == SubSeriesVerdict.SPLITS_PROPOSED


def test_filled_via_add_album_with_empty_added_coerces():
    decisions = _clean_decisions()
    decisions.gaps = GapsDecision(
        verdict=GapsVerdict.FILLED_VIA_ADD_ALBUM, reasoning="x",
    )
    review = assemble_review(_result(decisions), _empty_deps())
    assert review.decisions.gaps.verdict == GapsVerdict.DEFERRED


def test_pattern_updated_with_no_pattern_coerces():
    decisions = _clean_decisions()
    decisions.pattern = PatternDecision(
        verdict=PatternVerdict.PATTERN_UPDATED, reasoning="x",
    )
    review = assemble_review(_result(decisions), _empty_deps())
    assert review.decisions.pattern.verdict == PatternVerdict.DEFERRED


def test_outliers_excluded_via_overrides_with_empty_coerces():
    decisions = _clean_decisions()
    decisions.outliers = OutliersDecision(
        verdict=OutliersVerdict.EXCLUDED_VIA_OVERRIDES, reasoning="x",
    )
    review = assemble_review(_result(decisions), _empty_deps())
    assert review.decisions.outliers.verdict == OutliersVerdict.DEFERRED


def test_no_action_verdicts_dont_coerce():
    review = assemble_review(_result(), _empty_deps())
    assert review.decisions.duplicates.verdict == DuplicatesVerdict.NONE_FOUND
    assert review.decisions.sub_series.verdict == SubSeriesVerdict.NONE_FOUND


def test_coercion_is_independent_per_category():
    """One inconsistency doesn't affect another category's verdict."""
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES, reasoning="x",
    )
    decisions.sub_series = SubSeriesDecision(
        verdict=SubSeriesVerdict.SPLITS_PROPOSED, reasoning="x",
    )
    deps = _empty_deps()
    # Provide overrides but not splits — duplicates stays, sub_series coerces.
    deps.proposed_overrides.append({
        "album_id": "a", "provider": "spotify",
        "action": "exclude", "reason": "x",
    })
    review = assemble_review(_result(decisions), deps)
    assert review.decisions.duplicates.verdict == DuplicatesVerdict.RESOLVED_VIA_OVERRIDES
    assert review.decisions.sub_series.verdict == SubSeriesVerdict.DEFERRED


def test_assemble_returns_assembled_review_dataclass():
    review = assemble_review(_result(), _empty_deps())
    assert isinstance(review, AssembledReview)
    assert review.summary == "test"
