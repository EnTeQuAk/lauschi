"""A decision for an album the batch never contained is an invented id.

Luna produced one on Bibi Blocksberg (2026-08-31): apple_music
1143565835 "Folge 75: Die neue Lehrerin", an id that does not exist on
Apple Music, alongside the 496 albums it was given. Nothing dropped it,
and `apply` would have shipped it into series.yaml.
"""

import json
from pathlib import Path

import pytest

from lauschi_catalog.agent_deps import Progress
from lauschi_catalog.catalog.curate_ops import (
    AlbumAnswer,
    AlbumDecision,
    BatchAnswer,
    CuratedSeries,
    decisions_from_answer,
    save_curation,
)
from tests.factories import discovered_album


def _decide(
    batch: list[dict[str, str]],
    *answered: tuple[str, str],
    on_progress: Progress = lambda _message: None,
) -> tuple[list[AlbumDecision], list[str]]:
    """The decisions for a batch when the model answers for ``answered``."""
    answer = BatchAnswer(
        albums=[
            AlbumAnswer(provider=provider, id=album_id, include=True)
            for provider, album_id in answered
        ]
    )
    return decisions_from_answer(
        answer, batch, pattern=None, decided_by="test", on_progress=on_progress
    )


def test_decisions_for_ids_outside_the_batch_are_dropped_and_named() -> None:
    batch = [discovered_album("spotify", "a"), discovered_album("apple_music", "b")]
    progress: list[str] = []
    kept, orphans = _decide(
        batch,
        ("spotify", "a"),
        ("apple_music", "b"),
        ("apple_music", "ghost"),
        on_progress=progress.append,
    )
    assert [d.album_id for d in kept] == ["a", "b"]
    assert orphans == ["apple_music:ghost"]
    assert any("apple_music:ghost" in p for p in progress)


def test_the_same_id_on_the_other_provider_is_still_an_orphan() -> None:
    kept, orphans = _decide([discovered_album("spotify", "a")], ("apple_music", "a"))
    assert kept == []
    assert orphans == ["apple_music:a"]


def test_a_clean_batch_passes_through_whole() -> None:
    batch = [discovered_album("spotify", "a"), discovered_album("spotify", "b")]
    kept, orphans = _decide(batch, ("spotify", "a"), ("spotify", "b"))
    assert [(d.provider, d.album_id) for d in kept] == [
        ("spotify", "a"),
        ("spotify", "b"),
    ]
    assert orphans == []


def test_orphans_are_persisted_with_the_curation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    curation_dir = tmp_path / "assets" / "catalog" / "curation"
    curation_dir.mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    series = CuratedSeries(
        id="bibi_blocksberg",
        title="Bibi",
        albums=[],
        orphan_ids=["apple_music:1143565835"],
    )
    data = json.loads(save_curation(series).read_text())
    assert data["orphan_ids"] == ["apple_music:1143565835"]
