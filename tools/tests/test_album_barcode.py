"""Every full album record keeps the release's barcode.

The barcode (a UPC, an EAN or an ISBN-13) names a release on both stores
and in the reference index, so it ties a store id to the release it
stands for. Spotify's full album records carry it under
`external_ids`, its artist page lists none. Apple Music has `upc` on
every album record.
"""

from collections.abc import Callable

import pytest

from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.base import Album
from lauschi_catalog.providers.spotify import SpotifyProvider


@pytest.fixture
def spotify(monkeypatch: pytest.MonkeyPatch) -> SpotifyProvider:
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "sec")
    monkeypatch.setattr(SpotifyProvider, "_fetch_token", lambda self: "tok")
    return SpotifyProvider(use_cache=False)


@pytest.fixture
def apple(monkeypatch: pytest.MonkeyPatch) -> AppleMusicProvider:
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
    return AppleMusicProvider(use_cache=False)


def _spotify_raw(**extra: object) -> dict:
    return {
        "id": "s1",
        "name": "Folge 1: Der Sturm",
        "album_type": "album",
        "total_tracks": 12,
        "release_date": "2014-03-07",
        "images": [],
        "tracks": {"items": []},
        **extra,
    }


def _listed(p: SpotifyProvider | AppleMusicProvider) -> Callable[[dict], Album]:
    def parse(raw: dict) -> Album:
        p._cached = lambda key, fetch: [raw]  # type: ignore[method-assign]
        return p.artist_albums("artist")[0]

    return parse


@pytest.mark.parametrize(
    ("external_ids", "barcode"),
    [
        ({"upc": "4029759160373"}, "4029759160373"),
        ({"ean": "9783803286277"}, "9783803286277"),
        ({}, ""),
    ],
)
def test_spotify_keeps_the_barcode_of_a_full_album_record(
    spotify: SpotifyProvider, external_ids: dict[str, str], barcode: str
) -> None:
    raw = _spotify_raw(external_ids=external_ids)
    for parse in (spotify._album_from_details, spotify.raw_to_album):
        assert parse(raw).barcode == barcode


def test_spotify_artist_page_has_no_barcode(spotify: SpotifyProvider) -> None:
    assert _listed(spotify)(_spotify_raw()).barcode == ""


def test_apple_music_keeps_the_barcode_on_every_record(
    apple: AppleMusicProvider,
) -> None:
    raw = {"id": "a1", "attributes": {"name": "Folge 1", "upc": "190295911126"}}
    apple._cached = lambda key, fetch: [raw]  # type: ignore[method-assign]
    for album in (
        apple._album_from_details(raw),
        apple.raw_to_album(raw),
        apple.artist_albums("artist")[0],
        apple.search_albums("Folge 1")[0],
    ):
        assert album.barcode == "190295911126"


def test_both_stores_find_a_release_by_its_barcode(
    spotify: SpotifyProvider,
    apple: AppleMusicProvider,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    asked: list[tuple[str, dict]] = []

    def spotify_get(path: str, **params: object) -> dict:
        asked.append((path, params))
        return {"albums": {"items": [_spotify_raw()]}}

    def apple_get(path: str, **params: object) -> dict:
        asked.append((path, params))
        raw = {"id": "a1", "attributes": {"name": "Folge 1", "upc": "4029759160373"}}
        return {"data": [raw]}

    monkeypatch.setattr(spotify, "_get", spotify_get)
    monkeypatch.setattr(apple, "_get", apple_get)

    assert [a.id for a in spotify.albums_by_barcode("4029759160373")] == ["s1"]
    assert [a.id for a in apple.albums_by_barcode("4029759160373")] == ["a1"]
    assert [
        (path, params.get("q") or params.get("filter[upc]")) for path, params in asked
    ] == [
        ("search", "upc:4029759160373"),
        ("albums", "4029759160373"),
    ]
