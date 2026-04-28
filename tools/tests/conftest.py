"""Shared test fixtures for the lauschi-catalog test suite."""

from __future__ import annotations

from typing import Any


def make_album(
    album_id: str,
    title: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
) -> dict[str, Any]:
    """Build an album dict in the modern curation shape."""
    return {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": title,
        "exclude_reason": exclude_reason,
    }


def make_curation(
    *,
    series_id: str = "test_series",
    title: str = "Test Series",
    episode_pattern: str | list[str] | None = r"^Folge (\d+):",
    albums: list[dict[str, Any]] | None = None,
    review: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Build a curation dict matching the on-disk JSON shape."""
    data: dict[str, Any] = {
        "id": series_id,
        "title": title,
        "episode_pattern": episode_pattern,
        "albums": albums or [],
    }
    if review is not None:
        data["review"] = review
    return data


def make_clean_decisions() -> dict[str, dict[str, str]]:
    """Build a decisions dict for a curation with no defects.

    Returned shape matches StructuralReview.model_dump(): each category
    is ``{"verdict": "...", "reasoning": "..."}``. Useful when a test
    needs a valid ReviewResult but doesn't care about the per-category
    content. Constructing it as raw dicts avoids importing the pydantic
    models from review.py in fixtures that should stay light.
    """
    base = {"reasoning": "test fixture; analysis showed nothing to act on."}
    return {
        "duplicates": {"verdict": "no_within_provider_duplicates", **base},
        "sub_series": {"verdict": "no_sub_series_mixed_in", **base},
        "gaps": {"verdict": "no_gaps_present", **base},
        "pattern": {"verdict": "current_pattern_correct", **base},
        "outliers": {"verdict": "no_outliers_found", **base},
        "cross_provider": {"verdict": "balanced", **base},
    }
