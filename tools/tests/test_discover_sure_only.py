"""Tests that discover only writes IDs it is sure of."""

import pytest

from lauschi_catalog.catalog import discover_ops
from lauschi_catalog.catalog.discover_ops import (
    classify_match,
    match_artist,
)
from lauschi_catalog.catalog.io import load_raw
from lauschi_catalog.providers.base import Artist
from tests.conftest import ScratchCatalog


def _artist(
    name: str, provider: str = "spotify", genres: list[str] | None = None
) -> Artist:
    return Artist(
        id=f"id_{name.lower().replace(' ', '_')}",
        name=name,
        provider=provider,
        genres=genres or [],
    )


PLAYMOS = {
    "series": [{"id": "playmos", "title": "Die Playmos", "providers": {"spotify": {}}}]
}


class _FakeProvider:
    """Provider that returns the candidates we configure."""

    name = "spotify"

    def __init__(self, candidates: list[Artist]) -> None:
        self._candidates = candidates

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        return list(self._candidates)

    def artist_exists(self, _artist_id: str) -> bool:
        return True


def test_classify_match_exact_and_substring():
    exact = _artist("Die Playmos")
    sub = _artist("Die Playmos Hörspiele")
    unrelated = _artist("Playmobil")

    assert classify_match("Die Playmos", exact) == "exact"
    assert classify_match("Die Playmos", sub) == "substring"
    assert classify_match("Die Playmos", unrelated) == "weak"


def test_match_artist_stops_at_weak_when_multiple():
    """Two weak candidates should not return a match just because one exists."""
    candidates = [
        _artist("Various Hörspiele", genres=["Hörspiel"]),
        _artist("Kinderlieder ABC", genres=["Children"]),
    ]
    assert match_artist("Die Playmos", candidates) is None


def test_match_artist_single_candidate_is_weak():
    """A single weak candidate used to auto-win. It must not anymore."""
    candidates = [_artist("Random Artist", genres=["pop"])]
    assert match_artist("Die Playmos", candidates) is None


def test_match_artist_prefers_exact_over_substring():
    candidates = [
        _artist("Die Playmos Collection"),
        _artist("Die Playmos"),
    ]
    assert match_artist("Die Playmos", candidates).name == "Die Playmos"


def test_match_artist_substring_accepted_without_exact():
    candidates = [_artist("Die Playmos Hörspiele")]
    assert match_artist("Die Playmos", candidates).name == "Die Playmos Hörspiele"


def test_classify_match_genre_is_weak():
    """Genre-only confidence is the old behavior; classify still returns it,
    but the write path must treat it as not-sure.
    """
    artist = _artist("Completely Different Name", genres=["Hörspiel"])
    assert classify_match("Die Playmos", artist) == "genre"


def test_discover_all_only_writes_exact_and_substring(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    """Weak and genre-only matches are reported but not written."""
    scratch_catalog.write_series(*PLAYMOS["series"])

    exact = _artist("Die Playmos")
    weak = _artist("Random Artist", genres=["Hörspiel"])
    provider = _FakeProvider([exact, weak])

    monkeypatch.setattr(
        discover_ops, "update_provider_ids", lambda *, updates: len(updates)
    )

    result = discover_ops.discover_all(
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.found_total == 1
    assert "playmos" in result.updates
    assert result.updates["playmos"]["spotify"] == ["id_die_playmos"]
    assert result.written == 1


def test_discover_all_reports_weak_without_write(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    """When every candidate is weak, no IDs are written."""
    scratch_catalog.write_series(*PLAYMOS["series"])

    weak = _artist("Playmobil Soundtrack", genres=["Kinder"])
    provider = _FakeProvider([weak])

    monkeypatch.setattr(
        discover_ops, "update_provider_ids", lambda *, updates: len(updates)
    )

    result = discover_ops.discover_all(
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.found_total == 0
    assert result.updates == {}
    assert result.written == 0


COCO = {
    "series": [
        {
            "id": "coco",
            "title": "Coco",
            "providers": {
                "spotify": {
                    "no_artist_page": "Every artist named Coco is someone else.",
                    "albums": [{"id": "a1", "title": "Coco (Hörspiel)"}],
                }
            },
        }
    ]
}


class _NoSearch(_FakeProvider):
    """A provider that must not be searched."""

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        raise AssertionError(f"searched {query!r}")


def test_discover_all_skips_a_provider_without_an_artist_page(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    """An entry whose provider has no artist page of its own is not searched
    there: every artist of that name is someone else."""
    scratch_catalog.write_series(*COCO["series"])

    result = discover_ops.discover_all(
        [_NoSearch([_artist("Coco")])],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.updates == {}
    assert result.written == 0


def test_discover_one_writes_no_artist_id_where_there_is_no_artist_page(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    scratch_catalog.write_series(*COCO["series"])
    messages: list[str] = []

    result = discover_ops.discover_one(
        "coco",
        [_FakeProvider([_artist("Coco")])],
        write=True,
        on_progress=messages.append,
    )

    assert result.written is False
    assert load_raw(scratch_catalog.series_json) == COCO
    assert any("Every artist named Coco is someone else." in m for m in messages)
