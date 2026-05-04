"""Tests for verify._build_prompt — content the verifier sees.

The 4-eye check is only meaningful if the verifier can challenge the
first reviewer's rationale. These tests pin the contents of the
prompt so a future refactor doesn't silently drop the per-category
decisions or summary the verifier needs to do its job.
"""

from __future__ import annotations

from lauschi_catalog.commands.verify import _build_prompt


def _curation(*, review: dict | None = None) -> dict:
    return {
        "id": "s1",
        "title": "Test",
        "episode_pattern": r"^Folge (\d+):",
        "provider_artist_ids": {"spotify": ["a"]},
        "albums": [
            {"album_id": "a", "provider": "spotify", "include": True,
             "episode_num": 1, "title": "Folge 1: A"},
            {"album_id": "b", "provider": "spotify", "include": False,
             "title": "Box set", "exclude_reason": "compilation"},
        ],
        "review": review or {},
    }


def test_prompt_includes_per_category_decisions():
    """The verifier needs reasoning, not just verdicts. Each category
    that has a decision should appear in the prompt with its reasoning."""
    review = {
        "decisions": {
            "duplicates": {
                "verdict": "resolved_via_overrides",
                "reasoning": "spotify ep 47 had two album_ids; kept older",
            },
            "sub_series": {
                "verdict": "splits_proposed",
                "reasoning": "found 'Junior' cluster of 23 albums",
            },
            "gaps": {"verdict": "no_gaps_present", "reasoning": "1-238 contiguous"},
            "pattern": {"verdict": "current_pattern_correct", "reasoning": "all match"},
            "outliers": {"verdict": "no_outliers_found", "reasoning": "clean"},
            "cross_provider": {"verdict": "balanced", "reasoning": "symmetric"},
        },
    }
    prompt = _build_prompt(_curation(review=review))

    assert "per-category decisions" in prompt.lower()
    assert "duplicates: resolved_via_overrides" in prompt
    assert "spotify ep 47 had two album_ids" in prompt
    assert "sub_series: splits_proposed" in prompt
    assert "Junior" in prompt


def test_prompt_includes_review_summary():
    review = {
        "summary": "Series is in good shape; one duplicate handled.",
    }
    prompt = _build_prompt(_curation(review=review))

    assert "First reviewer summary" in prompt
    assert "good shape" in prompt


def test_prompt_truncates_long_reasoning():
    """Each category reasoning capped at 300 chars to keep prompt
    bounded — same shape constraint as upstream review."""
    long_reasoning = "x" * 1000
    review = {
        "decisions": {
            "duplicates": {"verdict": "no_within_provider_duplicates",
                           "reasoning": long_reasoning},
        },
    }
    prompt = _build_prompt(_curation(review=review))
    # 300 x's appear; 400 don't
    assert "x" * 300 in prompt
    assert "x" * 400 not in prompt


def test_prompt_omits_decision_section_when_no_decisions():
    """Old-format review with no decisions block: skip cleanly,
    don't render an empty header."""
    review = {"overrides": [], "splits": []}
    prompt = _build_prompt(_curation(review=review))
    assert "per-category decisions" not in prompt.lower()


def test_prompt_overrides_and_splits_still_present():
    """The pre-existing prompt contents (overrides, splits) survive
    the addition of the decisions section."""
    review = {
        "overrides": [{"action": "exclude", "provider": "spotify",
                       "album_id": "b", "reason": "compilation"}],
        "splits": [{"new_series_id": "sub", "new_series_title": "Sub",
                    "album_ids": ["a"], "provider": "spotify",
                    "reason": "different cast"}],
    }
    prompt = _build_prompt(_curation(review=review))
    assert "First reviewer overrides" in prompt
    assert "First reviewer split proposals" in prompt
    assert "compilation" in prompt
    assert "different cast" in prompt
