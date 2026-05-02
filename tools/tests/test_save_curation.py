"""Tests for curate.save_curation, focused on review-block preservation.

The bug this guards against: a re-curate (e.g., pipeline pulling fresh
albums from providers) used to overwrite the curation file with a flat
dict that had no ``review`` key, wiping every prior override, split,
decision, status, and verification. Now save_curation reads the
existing file and carries the review block through the rewrite.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from lauschi_catalog.commands import curate as curate_mod
from lauschi_catalog.commands.curate import (
    AlbumDecision,
    CuratedSeries,
    save_curation,
)


@pytest.fixture
def curation_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(curate_mod, "CURATION_DIR", tmp_path)
    return tmp_path


def _series(sid: str = "test_series", *, albums: list[AlbumDecision] | None = None) -> CuratedSeries:
    return CuratedSeries(
        id=sid,
        title="Test Series",
        content_type="hoerspiel",
        episode_pattern=r"^Folge (\d+):",
        provider_artist_ids={"spotify": ["x"]},
        albums=albums or [
            AlbumDecision(
                album_id="a", provider="spotify", include=True,
                episode_num=1, title="Folge 1: A", exclude_reason=None,
            ),
        ],
    )


def _write_existing(path: Path, sid: str, review: dict[str, Any] | None = None) -> Path:
    p = path / f"{sid}.json"
    data: dict[str, Any] = {
        "id": sid,
        "title": "Old Title",
        "albums": [{"album_id": "old", "provider": "spotify",
                    "include": True, "title": "Folge 1: Old"}],
    }
    if review is not None:
        data["review"] = review
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return p


def test_save_curation_creates_new_file_without_review(curation_dir: Path):
    """Brand-new curation: no prior file, no review block in output."""
    save_curation(_series("fresh"))
    saved = json.loads((curation_dir / "fresh.json").read_text())
    assert saved["id"] == "fresh"
    assert "review" not in saved


def test_save_curation_preserves_existing_review_block(curation_dir: Path):
    """The bug fix: re-curating doesn't wipe the prior review."""
    review = {
        "status": "approved",
        "overrides": [
            {"album_id": "x", "provider": "spotify",
             "action": "exclude", "reason": "duplicate"},
        ],
        "splits": [],
        "added_albums": [],
        "decisions": {"duplicates": {"verdict": "resolved_via_overrides", "reasoning": "x"}},
        "summary": "all good",
    }
    _write_existing(curation_dir, "test_series", review=review)

    save_curation(_series("test_series"))

    saved = json.loads((curation_dir / "test_series.json").read_text())
    assert saved["review"] == review
    assert saved["review"]["status"] == "approved"
    assert saved["review"]["overrides"][0]["album_id"] == "x"


def test_save_curation_replaces_curate_owned_fields(curation_dir: Path):
    """Curate-side fields (title, albums, etc.) get the new values."""
    _write_existing(curation_dir, "test_series", review={"status": "approved"})

    save_curation(_series("test_series"))

    saved = json.loads((curation_dir / "test_series.json").read_text())
    assert saved["title"] == "Test Series"  # new
    assert saved["albums"][0]["album_id"] == "a"  # new
    assert "old" not in str(saved["albums"])  # old replaced
    assert saved["review"]["status"] == "approved"  # review preserved


def test_save_curation_skips_empty_review_dict(curation_dir: Path):
    """An empty {} review block (e.g., curate just stamping
    reviewed_at) shouldn't be carried forward as a fake review."""
    _write_existing(curation_dir, "test_series", review={})

    save_curation(_series("test_series"))

    saved = json.loads((curation_dir / "test_series.json").read_text())
    # Empty dict is falsy → not preserved → absent on save
    assert "review" not in saved


def test_save_curation_handles_corrupt_existing_file(curation_dir: Path):
    """Unparseable JSON shouldn't block a fresh write."""
    p = curation_dir / "test_series.json"
    p.write_text("{not json at all")

    save_curation(_series("test_series"))

    saved = json.loads(p.read_text())
    assert saved["id"] == "test_series"
    assert "review" not in saved
