"""Tests that discover_one routes creation through add_series and
respects deleted.json."""

import pytest

from lauschi_catalog.catalog.discover_ops import (
    DiscoverMatch,
    _artist_to_match,
    discover_one,
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


class _FakeProvider:
    name = "spotify"

    def __init__(self, candidates: list[Artist]) -> None:
        self._candidates = candidates

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        return list(self._candidates)

    def artist_exists(self, _artist_id: str) -> bool:
        return True


@pytest.mark.anyio
async def test_discover_one_creates_series_with_sure_matches(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    scratch_catalog.write_series()

    provider = _FakeProvider([_artist("Die Playmos")])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is True
    assert result.new_series_id == "die_playmos"
    assert result.written is True
    catalog = load_raw(scratch_catalog.series_json)
    assert any(e.get("id") == "die_playmos" for e in catalog.get("series", []))


@pytest.mark.anyio
async def test_discover_one_skips_creation_when_only_weak_match(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    scratch_catalog.write_series()

    provider = _FakeProvider([_artist("Playmobil Soundtrack", genres=["Kinder"])])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is False
    assert result.written is False


@pytest.mark.anyio
async def test_discover_one_refuses_deleted_series(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
):
    """A deleted series id should not be re-created by discover --write."""
    scratch_catalog.write_series()
    scratch_catalog.deleted_log.write_text(
        '{"deleted": [{"id": "die_playmos", "title": "Die Playmos", "reason": "test"}]}\n'
    )

    provider = _FakeProvider([_artist("Die Playmos")])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is False
    assert result.written is False


def test_artist_to_match_confidence_is_exact_or_substring():
    """The confidence used by the write path only trusts exact/substring."""
    exact = _artist("Die Playmos")
    assert _artist_to_match(exact, "exact").confidence == "exact"
    assert _artist_to_match(exact, "substring").confidence == "substring"
    assert _artist_to_match(exact, "genre").confidence == "genre"


def test_discover_match_model_stores_confidence():
    m = DiscoverMatch(
        provider="spotify",
        artist_id="id_die_playmos",
        artist_name="Die Playmos",
        confidence="exact",
    )
    assert m.confidence == "exact"
