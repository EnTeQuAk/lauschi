"""Tests for review.save_review.

save_review owns several tricky behaviors that aren't unit-tested
elsewhere: pattern_update applies deterministically, the review block
is updated in place (verification preserved), status resets to
ai_reviewed when actions are proposed, and added_albums get merged
into the main album list.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from lauschi_catalog.commands import review as review_mod
from lauschi_catalog.commands.review import (
    AddedAlbum,
    DuplicatesDecision,
    GapsDecision,
    OutliersDecision,
    PatternDecision,
    ReviewOverride,
    ReviewResult,
    StructuralReview,
    SubSeriesDecision,
    CrossProviderDecision,
    save_review,
)

from .conftest import make_album, make_curation


@pytest.fixture
def curation_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point save_review at a temp directory for the test."""
    monkeypatch.setattr(review_mod, "CURATION_DIR", tmp_path)
    return tmp_path


def _clean_decisions() -> StructuralReview:
    """A StructuralReview where every category says 'nothing to do'."""
    r = "test fixture"
    return StructuralReview(
        duplicates=DuplicatesDecision(
            verdict="no_within_provider_duplicates", reasoning=r,
        ),
        sub_series=SubSeriesDecision(verdict="no_sub_series_mixed_in", reasoning=r),
        gaps=GapsDecision(verdict="no_gaps_present", reasoning=r),
        pattern=PatternDecision(verdict="current_pattern_correct", reasoning=r),
        outliers=OutliersDecision(verdict="no_outliers_found", reasoning=r),
        cross_provider=CrossProviderDecision(verdict="balanced", reasoning=r),
    )


def _make_result(
    *,
    overrides: list[ReviewOverride] | None = None,
    splits: list | None = None,
    added_albums: list[AddedAlbum] | None = None,
    pattern_update: str | list[str] | None = None,
    decisions: StructuralReview | None = None,
    summary: str = "test review",
) -> ReviewResult:
    """Construct a ReviewResult with sensible no-op defaults."""
    return ReviewResult(
        overrides=overrides or [],
        splits=splits or [],
        added_albums=added_albums or [],
        pattern_update=pattern_update,
        decisions=decisions or _clean_decisions(),
        summary=summary,
    )


def _write_curation(path: Path, sid: str, data: dict[str, Any]) -> Path:
    p = path / f"{sid}.json"
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return p


# ── persistence ────────────────────────────────────────────────────────────


def test_save_review_persists_action_lists(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    ))
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides",
        reasoning="ep 1 had two album_ids on spotify, kept older",
    )
    result = _make_result(
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="test",
        )],
        decisions=decisions,
        summary="test run",
    )
    save_review("s1", result)

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["overrides"][0]["album_id"] == "a"
    assert saved["review"]["summary"] == "test run"
    assert "reviewed_at" in saved["review"]


def test_save_review_persists_decisions_block(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    ))
    save_review("s1", _make_result())

    saved = json.loads((curation_dir / "s1.json").read_text())
    decisions = saved["review"]["decisions"]
    assert set(decisions.keys()) == {
        "duplicates", "sub_series", "gaps",
        "pattern", "outliers", "cross_provider",
    }
    assert decisions["duplicates"]["verdict"] == "no_within_provider_duplicates"
    assert "reasoning" in decisions["duplicates"]


def test_save_review_drops_legacy_notes_field(curation_dir: Path):
    """Pre-strict-schema reviews used a notes string. New saves should
    remove that field rather than carry both shapes side by side."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"notes": "old prose blob from prior review", "status": "approved"},
    ))
    save_review("s1", _make_result(summary="new clean summary"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert "notes" not in saved["review"]
    assert saved["review"]["summary"] == "new clean summary"


# ── status reset ───────────────────────────────────────────────────────────


def test_save_review_preserves_existing_verification_when_no_actions(curation_dir: Path):
    """When the agent proposes nothing new, verify state stays trusted."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "verification": {"model": "minimax-m2.7", "approve": True},
        },
    ))
    save_review("s1", _make_result(summary="all good"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "approved"
    assert saved["review"]["verification"]["approve"] is True


def test_save_review_resets_status_when_actions_proposed(curation_dir: Path):
    """New overrides invalidate any prior approval; verify must re-run."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "verification": {"model": "minimax-m2.7", "approve": True},
        },
    ))
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict="resolved_via_overrides", reasoning="found one",
    )
    result = _make_result(
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
        decisions=decisions,
    )
    save_review("s1", result)

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


def test_save_review_resets_status_for_pattern_update_only(curation_dir: Path):
    """Pattern update alone counts as an action — status should reset."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        episode_pattern=r"^Folge (\d+):",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"status": "approved", "verification": {"approve": True}},
    ))
    decisions = _clean_decisions()
    decisions.pattern = PatternDecision(
        verdict="pattern_updated", reasoning="newer titles use slash",
    )
    save_review("s1", _make_result(
        pattern_update=r"^(\d+):", decisions=decisions,
    ))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


# ── pattern application ────────────────────────────────────────────────────


def test_save_review_applies_pattern_update_and_re_extracts(curation_dir: Path):
    """When pattern_update is set, the saved curation gets the new pattern
    and all album episode_nums are re-extracted under it."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        episode_pattern=r"^Folge (\d+):",
        albums=[
            make_album("a", "47/Title", episode_num=None),
            make_album("b", "48/Title", episode_num=None),
            make_album("c", "Folge 1: Old", episode_num=1),
        ],
    ))
    decisions = _clean_decisions()
    decisions.pattern = PatternDecision(
        verdict="pattern_updated", reasoning="slash format",
    )
    save_review("s1", _make_result(
        pattern_update=r"^(\d+)/", decisions=decisions,
    ))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["episode_pattern"] == r"^(\d+)/"
    by_id = {a["album_id"]: a for a in saved["albums"]}
    assert by_id["a"]["episode_num"] == 47
    assert by_id["b"]["episode_num"] == 48
    # 'c' doesn't match the new pattern; episode_num is preserved (1)
    assert by_id["c"]["episode_num"] == 1


# ── added_albums merge ─────────────────────────────────────────────────────


def test_save_review_merges_added_albums_into_main_list(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("existing", "Folge 1: Existing", episode_num=1)],
    ))
    decisions = _clean_decisions()
    decisions.gaps = GapsDecision(
        verdict="filled_via_add_album", reasoning="found ep 2 on spotify",
    )
    result = _make_result(
        added_albums=[AddedAlbum(
            album_id="new",
            provider="spotify",
            title="Folge 2: New",
            episode_num=2,
            evidence_url="https://hoerspiele.de/some-page",
        )],
        decisions=decisions,
    )
    save_review("s1", result)

    saved = json.loads((curation_dir / "s1.json").read_text())
    album_ids = {a["album_id"] for a in saved["albums"]}
    assert album_ids == {"existing", "new"}
    new_album = next(a for a in saved["albums"] if a["album_id"] == "new")
    assert new_album["include"] is True
    assert new_album["evidence_url"] == "https://hoerspiele.de/some-page"


def test_save_review_does_not_double_add_existing_album_id(curation_dir: Path):
    """If the agent re-adds an album_id that's already in albums, no duplicate row."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("dup", "Folge 1: Dup", episode_num=1)],
    ))
    decisions = _clean_decisions()
    decisions.gaps = GapsDecision(
        verdict="filled_via_add_album", reasoning="dup",
    )
    result = _make_result(
        added_albums=[AddedAlbum(
            album_id="dup",
            provider="spotify",
            title="Folge 1: Re-added",
            episode_num=1,
            evidence_url="https://example.com",
        )],
        decisions=decisions,
    )
    save_review("s1", result)

    saved = json.loads((curation_dir / "s1.json").read_text())
    matching = [a for a in saved["albums"] if a["album_id"] == "dup"]
    assert len(matching) == 1


def test_save_review_raises_when_curation_file_missing(curation_dir: Path):
    with pytest.raises(SystemExit):
        save_review("nonexistent", _make_result())
