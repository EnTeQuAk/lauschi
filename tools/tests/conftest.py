"""Shared test fixtures for the lauschi-catalog test suite."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.io import write_catalog


@dataclass(frozen=True)
class ScratchCatalog:
    """A checkout in ``tmp_path`` that every catalog path resolves into.

    It starts with an empty curation directory and no series.json, so a
    test writes only the files it is about.
    """

    root: Path
    series_json: Path
    curation_dir: Path
    deleted_log: Path

    def write_series(self, *entries: dict[str, Any]) -> None:
        """Write series.json holding ``entries``."""
        write_catalog(self.series_json, {"series": list(entries)})

    def write_curation(self, data: dict[str, Any]) -> Path:
        """Write a curation file, named by its ``id``."""
        path = self.curation_dir / f"{data['id']}.json"
        path.write_text(json.dumps(data))
        return path

    def read_curation(self, series_id: str) -> dict[str, Any]:
        return json.loads((self.curation_dir / f"{series_id}.json").read_text())


@pytest.fixture
def scratch_catalog(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ScratchCatalog:
    """Point ``LAUSCHI_REPO_ROOT`` at ``tmp_path``, so nothing a test writes
    reaches the checkout's catalog."""
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    paths.curation_dir().mkdir(parents=True)
    return ScratchCatalog(
        root=tmp_path,
        series_json=paths.catalog_path(),
        curation_dir=paths.curation_dir(),
        deleted_log=paths.deleted_log_path(),
    )


def make_album(
    album_id: str,
    title: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
    release_date: str | None = None,
) -> dict[str, Any]:
    """Build an album dict in the modern curation shape."""
    return {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": title,
        "exclude_reason": exclude_reason,
        "release_date": release_date,
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
