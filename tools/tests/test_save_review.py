"""Tests for review.save_review.

save_review takes an AssembledReview (built by assemble_review from
the model output + deps state) and persists it. Pinned behaviors:
- writes the structured fields to review.*
- preserves verify state when no actions / deferrals are present
- resets status to ai_reviewed when actions or deferrals are present
- applies pattern_update deterministically + re-extracts episode_nums
- merges added_albums into the main albums list
- drops the legacy ``notes`` field on save
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from lauschi_catalog.commands import review as review_mod
from lauschi_catalog.commands.review import (
    AddedAlbum,
    AssembledReview,
    CrossProviderDecision,
    CrossProviderVerdict,
    DuplicatesDecision,
    DuplicatesVerdict,
    GapsDecision,
    GapsVerdict,
    OutliersDecision,
    OutliersVerdict,
    PatternDecision,
    PatternVerdict,
    ReviewOverride,
    SplitProposal,
    StructuralReview,
    SubSeriesDecision,
    SubSeriesVerdict,
    save_review,
)

from .conftest import make_album, make_curation


@pytest.fixture
def curation_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(review_mod, "CURATION_DIR", tmp_path)
    return tmp_path


def _write_curation(path: Path, sid: str, data: dict[str, Any]) -> Path:
    p = path / f"{sid}.json"
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return p


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


def _make_review(
    *,
    overrides: list[ReviewOverride] | None = None,
    splits: list[SplitProposal] | None = None,
    added_albums: list[AddedAlbum] | None = None,
    pattern_update: str | list[str] | None = None,
    decisions: StructuralReview | None = None,
    summary: str = "test review",
) -> AssembledReview:
    return AssembledReview(
        overrides=overrides or [],
        splits=splits or [],
        added_albums=added_albums or [],
        pattern_update=pattern_update,
        decisions=decisions or _clean_decisions(),
        summary=summary,
    )


# ── persistence ───────────────────────────────────────────────────────────


def test_save_review_persists_action_lists(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    ))
    decisions = _clean_decisions()
    decisions.duplicates = DuplicatesDecision(
        verdict=DuplicatesVerdict.RESOLVED_VIA_OVERRIDES,
        reasoning="ep 1 had two album_ids on spotify",
    )
    review = _make_review(
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="test",
        )],
        decisions=decisions,
        summary="test run",
    )
    save_review("s1", review)

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["overrides"][0]["album_id"] == "a"
    assert saved["review"]["summary"] == "test run"
    assert "reviewed_at" in saved["review"]


def test_save_review_persists_decisions_block(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    ))
    save_review("s1", _make_review())

    saved = json.loads((curation_dir / "s1.json").read_text())
    decisions = saved["review"]["decisions"]
    assert set(decisions.keys()) == {
        "duplicates", "sub_series", "gaps",
        "pattern", "outliers", "cross_provider",
    }
    assert decisions["duplicates"]["verdict"] == "no_within_provider_duplicates"


def test_save_review_drops_legacy_notes_field(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"notes": "old prose blob from prior review", "status": "approved"},
    ))
    save_review("s1", _make_review(summary="new clean summary"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert "notes" not in saved["review"]
    assert saved["review"]["summary"] == "new clean summary"


# ── status reset ──────────────────────────────────────────────────────────


def test_save_review_preserves_existing_verification_when_no_actions(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "verification": {"model": "minimax-m2.7", "approve": True},
        },
    ))
    save_review("s1", _make_review(summary="all good"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "approved"
    assert saved["review"]["verification"]["approve"] is True


def test_save_review_resets_status_when_actions_proposed(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "verification": {"model": "minimax-m2.7", "approve": True},
        },
    ))
    review = _make_review(
        overrides=[ReviewOverride(
            album_id="a", provider="spotify", action="exclude", reason="x",
        )],
    )
    save_review("s1", review)

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


def test_save_review_resets_status_when_any_verdict_is_deferred(curation_dir: Path):
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
        verdict=DuplicatesVerdict.DEFERRED,
        reasoning="too complex to structure cleanly",
    )
    save_review("s1", _make_review(decisions=decisions))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


def test_save_review_resets_status_when_cross_provider_is_deferred(curation_dir: Path):
    """Each verdict enum has its own DEFERRED member; the re-verification
    check must catch every category. cross_provider is the canary because
    it has the smallest non-action verdict set."""
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "verification": {"model": "minimax-m2.7", "approve": True},
        },
    ))
    decisions = _clean_decisions()
    decisions.cross_provider = CrossProviderDecision(
        verdict=CrossProviderVerdict.DEFERRED,
        reasoning="apple_music coverage gap unexplained",
    )
    save_review("s1", _make_review(decisions=decisions))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


def test_save_review_resets_status_for_pattern_update_only(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        episode_pattern=r"^Folge (\d+):",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"status": "approved", "verification": {"approve": True}},
    ))
    save_review("s1", _make_review(pattern_update=r"^(\d+):"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["review"]["status"] == "ai_reviewed"
    assert "verification" not in saved["review"]


# ── pattern application ───────────────────────────────────────────────────


def test_save_review_applies_pattern_update_and_re_extracts(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        episode_pattern=r"^Folge (\d+):",
        albums=[
            make_album("a", "47/Title", episode_num=None),
            make_album("b", "48/Title", episode_num=None),
            make_album("c", "Folge 1: Old", episode_num=1),
        ],
    ))
    save_review("s1", _make_review(pattern_update=r"^(\d+)/"))

    saved = json.loads((curation_dir / "s1.json").read_text())
    assert saved["episode_pattern"] == r"^(\d+)/"
    by_id = {a["album_id"]: a for a in saved["albums"]}
    assert by_id["a"]["episode_num"] == 47
    assert by_id["b"]["episode_num"] == 48
    assert by_id["c"]["episode_num"] == 1


# ── added_albums merge ────────────────────────────────────────────────────


def test_save_review_merges_added_albums_into_main_list(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("existing", "Folge 1: Existing", episode_num=1)],
    ))
    review = _make_review(
        added_albums=[AddedAlbum(
            album_id="new",
            provider="spotify",
            title="Folge 2: New",
            episode_num=2,
            evidence_url="https://hoerspiele.de/some-page",
        )],
    )
    save_review("s1", review)

    saved = json.loads((curation_dir / "s1.json").read_text())
    album_ids = {a["album_id"] for a in saved["albums"]}
    assert album_ids == {"existing", "new"}
    new_album = next(a for a in saved["albums"] if a["album_id"] == "new")
    assert new_album["include"] is True
    assert new_album["evidence_url"] == "https://hoerspiele.de/some-page"


def test_save_review_does_not_double_add_existing_album_id(curation_dir: Path):
    _write_curation(curation_dir, "s1", make_curation(
        series_id="s1",
        albums=[make_album("dup", "Folge 1: Dup", episode_num=1)],
    ))
    review = _make_review(
        added_albums=[AddedAlbum(
            album_id="dup",
            provider="spotify",
            title="Folge 1: Re-added",
            episode_num=1,
            evidence_url="https://example.com",
        )],
    )
    save_review("s1", review)

    saved = json.loads((curation_dir / "s1.json").read_text())
    matching = [a for a in saved["albums"] if a["album_id"] == "dup"]
    assert len(matching) == 1


def test_save_review_raises_when_curation_file_missing(curation_dir: Path):
    with pytest.raises(SystemExit):
        save_review("nonexistent", _make_review())
