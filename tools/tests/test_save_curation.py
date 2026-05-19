"""Tests for curate.save_curation.

Guards against re-curation silently overwriting audit state or
unrelated keys in the curation JSON. save_curation reads the
existing file, overwrites curate-owned fields, and preserves
everything else. When the album set changes, stale audit state
(overrides, concerns) is cleared since it references old album IDs.
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


def _write_existing(path: Path, sid: str, review: dict[str, Any] | None = None, album_id: str = "old") -> Path:
    p = path / f"{sid}.json"
    data: dict[str, Any] = {
        "id": sid,
        "title": "Old Title",
        "albums": [{"album_id": album_id, "provider": "spotify",
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
    _write_existing(curation_dir, "test_series", review=review, album_id="a")

    save_curation(_series("test_series"))

    saved = json.loads((curation_dir / "test_series.json").read_text())
    assert saved["review"] == review
    assert saved["review"]["status"] == "approved"
    assert saved["review"]["overrides"][0]["album_id"] == "x"


def test_save_curation_replaces_curate_owned_fields(curation_dir: Path):
    """Curate-side fields (title, albums, etc.) get the new values.
    When album IDs change, stale audit state is cleared."""
    _write_existing(curation_dir, "test_series", review={"status": "approved"})

    save_curation(_series("test_series"))

    saved = json.loads((curation_dir / "test_series.json").read_text())
    assert saved["title"] == "Test Series"  # new
    assert saved["albums"][0]["album_id"] == "a"  # new
    assert "old" not in str(saved["albums"])  # old replaced
    assert "status" not in saved.get("review", {})  # stale audit cleared


def test_save_curation_preserves_unrelated_keys(curation_dir: Path):
    """Anything outside the curate-owned set is carried forward —
    that's the architectural property: curate only touches its own
    fields, leaves the rest alone. Future pipeline steps can add new
    top-level subkeys without curate needing to know about them."""
    p = curation_dir / "test_series.json"
    p.write_text(json.dumps({
        "id": "test_series",
        "title": "Old",
        "review": {"status": "approved"},
        "verification_log": [{"step": "verify", "ts": "2026-01-01"}],
        "custom_human_field": "preserve me too",
    }))

    save_curation(_series("test_series"))

    saved = json.loads(p.read_text())
    assert saved["review"] == {"status": "approved"}
    assert saved["verification_log"] == [{"step": "verify", "ts": "2026-01-01"}]
    assert saved["custom_human_field"] == "preserve me too"
    # Curate-owned field still updated
    assert saved["title"] == "Test Series"


def test_save_curation_aborts_on_corrupt_existing_file(curation_dir: Path):
    """Refuse to overwrite an unparseable file. Reasoning: a partial
    write to a JSON that previously held an approved review block
    would otherwise be silently destroyed when save_curation falls
    back to data={}. Make the user inspect/move the file instead."""
    p = curation_dir / "test_series.json"
    p.write_text("{not json at all")

    with pytest.raises(SystemExit):
        save_curation(_series("test_series"))

    # File untouched — still the corrupt content the user can recover from
    assert p.read_text() == "{not json at all"
