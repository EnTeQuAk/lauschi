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
