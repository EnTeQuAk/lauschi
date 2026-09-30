"""A shipped album the artist page stopped listing stays while it exists.

Spotify dropped six Volker Rosin albums and Unter meinem Bett's
Weihnachtsalbum from their artist pages (2026-09-30). The albums still
resolve by id under the same artist, so they still play in the app.
Curate only saw the page, so the next apply would have removed them.
Each shipped album discovery misses is looked up by id: one that
exists is carried like a discovered album, one the provider no longer
knows is dropped, and one that cannot be checked makes the run
incomplete instead of being guessed either way.
"""

from lauschi_catalog.catalog.curate_ops import keep_unlisted_shipped
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.providers import Album, AlbumBatch


class _Provider:
    name = "spotify"

    def __init__(self, known: set[str], unverified: set[str] = frozenset()) -> None:
        self.known = known
        self.unverified = unverified
        self.asked: list[list[str]] = []

    def albums_by_ids(self, album_ids: list[str]) -> AlbumBatch:
        self.asked.append(list(album_ids))
        return AlbumBatch(
            albums=[
                Album(id=i, name=f"Album {i}", provider="spotify")
                for i in album_ids
                if i in self.known
            ],
            unverified=[i for i in album_ids if i in self.unverified],
        )


def _entry(*ids: str) -> CatalogEntry:
    albums = [{"id": i, "title": f"Album {i}"} for i in ids]
    return CatalogEntry(
        id="volker_rosin",
        title="Volker Rosin",
        providers={
            "spotify": ProviderConfig(
                artist_ids=["art"], album_ids=list(ids), albums=albums
            )
        },
    )


def _listed(*ids: str) -> list[dict]:
    return [{"provider": "spotify", "id": i, "name": f"Album {i}"} for i in ids]


def test_an_unlisted_album_that_still_exists_is_kept() -> None:
    provider = _Provider(known={"gone_from_page"})
    progress: list[str] = []
    albums, errors = keep_unlisted_shipped(
        _listed("on_page"),
        [provider],
        _entry("on_page", "gone_from_page"),
        progress.append,
    )
    assert [a["id"] for a in albums] == ["on_page", "gone_from_page"]
    assert errors == []
    assert provider.asked == [["gone_from_page"]]
    assert any("gone_from_page" in p or "1 shipped" in p for p in progress)


def test_an_album_the_provider_no_longer_knows_is_dropped() -> None:
    progress: list[str] = []
    albums, errors = keep_unlisted_shipped(
        _listed("on_page"),
        [_Provider(known=set())],
        _entry("on_page", "withdrawn"),
        progress.append,
    )
    assert [a["id"] for a in albums] == ["on_page"]
    assert errors == []
    assert any("withdrawn" in p for p in progress)


def test_an_album_that_cannot_be_checked_makes_the_run_incomplete() -> None:
    albums, errors = keep_unlisted_shipped(
        _listed("on_page"),
        [_Provider(known=set(), unverified={"flaky"})],
        _entry("on_page", "flaky"),
        lambda _m: None,
    )
    assert [a["id"] for a in albums] == ["on_page"]
    assert errors and "flaky" in errors[0]


def test_nothing_is_asked_when_the_page_lists_everything() -> None:
    provider = _Provider(known=set())
    albums, errors = keep_unlisted_shipped(
        _listed("a", "b"), [provider], _entry("a", "b"), lambda _m: None
    )
    assert [a["id"] for a in albums] == ["a", "b"] and errors == []
    assert provider.asked == []
