"""Regression tests for provider discovery counts."""

import pytest

from lauschi_catalog.catalog.curate_ops import _run_discovery
from lauschi_catalog.providers import Album


class _FakeProvider:
    def __init__(self, name: str, albums: dict[str, list[Album]]) -> None:
        self.name = name
        self._albums = albums
        self.searched: list[str] = []

    def search_artists(self, query: str):
        self.searched.append(query)
        return []

    def artist_albums(self, artist_id: str) -> list[Album]:
        return self._albums.get(artist_id, [])


@pytest.mark.anyio
async def test_known_artist_zero_albums_marks_incomplete() -> None:
    """The zero-album collapse check must fire for known artist IDs too."""
    providers = [
        _FakeProvider("spotify", {"spotify-artist": []}),
        _FakeProvider(
            "apple_music",
            {"apple-artist": [Album(id="a", name="A", provider="apple_music")]},
        ),
    ]
    known = {"spotify": ["spotify-artist"], "apple_music": ["apple-artist"]}

    result = await _run_discovery(
        "Test",
        providers,
        known_artist_ids=known,
        on_progress=lambda _m: None,
    )

    assert result.incomplete is True
    assert any("spotify" in e and "0 albums" in e for e in result.provider_errors)


@pytest.mark.anyio
async def test_known_artist_counts_recorded() -> None:
    """Discovery must record album counts for known artist IDs."""
    providers = [
        _FakeProvider(
            "spotify",
            {"spotify-artist": [Album(id="s1", name="S1", provider="spotify")]},
        ),
        _FakeProvider(
            "apple_music",
            {"apple-artist": [Album(id="a1", name="A1", provider="apple_music")]},
        ),
    ]
    known = {"spotify": ["spotify-artist"], "apple_music": ["apple-artist"]}

    result = await _run_discovery(
        "Test",
        providers,
        known_artist_ids=known,
        on_progress=lambda _m: None,
    )

    assert result.incomplete is False
    assert len(result.all_albums) == 2
    assert {a["provider"] for a in result.all_albums} == {"spotify", "apple_music"}
    assert result.artist_ids == known


@pytest.mark.anyio
async def test_search_branch_counts_recorded() -> None:
    """Discovery must record album counts for the searched-artist branch too."""

    class _SearchProvider(_FakeProvider):
        def search_artists(self, query: str):
            from lauschi_catalog.providers import Artist

            return [Artist(id="found", name="Found", provider=self.name)]

    providers = [
        _SearchProvider(
            "spotify",
            {"found": [Album(id="s1", name="S1", provider="spotify")]},
        ),
    ]

    result = await _run_discovery(
        "Test",
        providers,
        on_progress=lambda _m: None,
    )

    assert result.incomplete is False
    assert len(result.all_albums) == 1
    assert result.artist_ids == {"spotify": ["found"]}


@pytest.mark.anyio
async def test_a_store_without_an_artist_page_is_not_searched() -> None:
    """Every Apple Music artist named Coco is an unrelated music act. A
    search there picked one, and curate read its 238 singles on every run."""
    spotify = _FakeProvider(
        "spotify", {"coco": [Album(id="s1", name="Coco", provider="spotify")]}
    )
    apple = _FakeProvider("apple_music", {})

    result = await _run_discovery(
        "Coco",
        [spotify, apple],
        known_artist_ids={"spotify": ["coco"]},
        no_artist_page={"apple_music": "every artist named Coco is someone else"},
        on_progress=lambda _m: None,
    )

    assert apple.searched == []
    assert "apple_music" not in result.artist_ids
    assert result.incomplete is False
