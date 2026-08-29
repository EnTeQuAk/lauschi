"""A decision for an album the batch never contained is an invented id.

Luna produced one on Bibi Blocksberg (2026-08-31): apple_music
1143565835 "Folge 75: Die neue Lehrerin", an id that does not exist on
Apple Music, alongside the 496 albums it was given. Nothing dropped it,
and `apply` would have shipped it into series.yaml.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    CuratedSeries,
    drop_orphan_decisions,
    save_curation,
)


def _decision(album_id: str, provider: str = "spotify") -> AlbumDecision:
    return AlbumDecision(
        album_id=album_id,
        provider=provider,
        include=True,
        episode_num=1,
        title=album_id,
    )


def test_decisions_for_ids_outside_the_batch_are_dropped_and_named() -> None:
    batch_ids = {("spotify", "a"), ("apple_music", "b")}
    decisions = [
        _decision("a"),
        _decision("b", "apple_music"),
        _decision("ghost", "apple_music"),
    ]
    progress: list[str] = []
    kept, orphans = drop_orphan_decisions(
        decisions, batch_ids, on_progress=progress.append
    )
    assert [d.album_id for d in kept] == ["a", "b"]
    assert orphans == ["apple_music:ghost"]
    assert any("apple_music:ghost" in p and "ghost" in p for p in progress)


def test_the_same_id_on_the_other_provider_is_still_an_orphan() -> None:
    kept, orphans = drop_orphan_decisions(
        [_decision("a", "apple_music")], {("spotify", "a")}
    )
    assert kept == []
    assert orphans == ["apple_music:a"]


def test_a_clean_batch_passes_through_untouched() -> None:
    decisions = [_decision("a"), _decision("b")]
    kept, orphans = drop_orphan_decisions(
        decisions, {("spotify", "a"), ("spotify", "b")}
    )
    assert kept == decisions
    assert orphans == []


def test_orphans_are_persisted_with_the_curation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(curate_ops, "CURATION_DIR", tmp_path)
    series = CuratedSeries(
        id="bibi_blocksberg",
        title="Bibi",
        albums=[],
        orphan_ids=["apple_music:1143565835"],
    )
    data = json.loads(save_curation(series).read_text())
    assert data["orphan_ids"] == ["apple_music:1143565835"]
