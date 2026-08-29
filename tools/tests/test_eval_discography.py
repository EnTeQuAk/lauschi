from __future__ import annotations

from dataclasses import dataclass

from lauschi_catalog.eval.discography import fetch_discography
from lauschi_catalog.eval.truth import AlbumKey


@dataclass
class _Album:
    id: str


class _Provider:
    def __init__(self, name: str, pages: dict[str, list[str]]) -> None:
        self.name = name
        self.pages = pages
        self.calls: list[str] = []

    def artist_albums(self, artist_id: str) -> list[_Album]:
        self.calls.append(artist_id)
        return [_Album(i) for i in self.pages.get(artist_id, [])]


def test_unions_every_known_artist_page_per_provider() -> None:
    spotify = _Provider("spotify", {"art1": ["a", "b"], "art2": ["b", "c"]})
    apple = _Provider("apple_music", {"x": ["1"]})
    got = fetch_discography(
        [spotify, apple], {"spotify": ["art1", "art2"], "apple_music": ["x"]}
    )
    assert got == {
        AlbumKey("spotify", "a"),
        AlbumKey("spotify", "b"),
        AlbumKey("spotify", "c"),
        AlbumKey("apple_music", "1"),
    }
    assert spotify.calls == ["art1", "art2"]


def test_a_provider_without_known_ids_contributes_nothing() -> None:
    # curate would fall back to a name search here; the eval does not,
    # because every sample series has curated artist ids and a search
    # could drift the universe away from what the runs saw.
    apple = _Provider("apple_music", {"x": ["1"]})
    assert fetch_discography([apple], {"spotify": ["art1"]}) == frozenset()
    assert apple.calls == []
