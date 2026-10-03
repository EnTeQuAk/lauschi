"""`album_type` is the store's own classification, the same on both stores.

The Spotify API has no EP type and returns EPs as `single`, so the
curator excluded 4-8 track EPs as `music_single` (3Berlin's "Cowgummi",
8 tracks) while Apple Music shipped the same release as "- EP"
(2026-10-03). Apple Music had the opposite problem: anything up to five
tracks counted as `ep`, Hörspiel episodes included, while the store's
own marker is the " - EP" title suffix.
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


def _spotify_raw(album_type: str, tracks: int) -> dict:
    return {
        "id": "s1",
        "name": "Cowgummi",
        "album_type": album_type,
        "album_group": album_type,
        "total_tracks": tracks,
        "release_date": "2020-01-01",
        "images": [],
        "tracks": {"items": []},
    }


def _apple_raw(name: str, tracks: int, **flags: bool) -> dict:
    return {
        "id": "a1",
        "attributes": {"name": name, "trackCount": tracks, **flags},
    }


def _spotify_paths(p: SpotifyProvider) -> list[Callable[[dict], Album]]:
    def listed(raw: dict) -> Album:
        p._cached = lambda key, fetch: [raw]  # type: ignore[method-assign]
        return p.artist_albums("artist")[0]

    return [p._album_from_details, p.raw_to_album, listed]


def _apple_paths(p: AppleMusicProvider) -> list[Callable[[dict], Album]]:
    def listed(raw: dict) -> Album:
        p._cached = lambda key, fetch: [raw]  # type: ignore[method-assign]
        return p.artist_albums("artist")[0]

    return [p._album_from_details, p.raw_to_album, listed]


@pytest.mark.parametrize(
    ("api_type", "tracks", "expected"),
    [
        ("single", 1, "single"),
        ("single", 3, "single"),
        ("single", 4, "ep"),
        ("single", 8, "ep"),
        ("album", 4, "album"),
        ("compilation", 30, "compilation"),
    ],
)
def test_spotify_reports_a_single_of_four_or_more_tracks_as_an_ep(
    spotify: SpotifyProvider, api_type: str, tracks: int, expected: str
) -> None:
    for parse in _spotify_paths(spotify):
        assert parse(_spotify_raw(api_type, tracks)).album_type == expected


@pytest.mark.parametrize(
    ("name", "tracks", "flags", "expected"),
    [
        ("Pyjama Party - EP", 6, {}, "ep"),
        ("Folge 10: Babysitter? Nein Danke! - EP", 2, {}, "ep"),
        ("Folge 3: Der Zauberhut", 3, {}, "album"),
        ("Cowgummi", 12, {}, "album"),
        ("Mit der Bahn - Single", 4, {"isSingle": True}, "single"),
        ("Die schönsten Kinderlieder", 40, {"isCompilation": True}, "compilation"),
    ],
)
def test_apple_music_takes_the_type_from_its_flags_and_ep_suffix(
    apple: AppleMusicProvider,
    name: str,
    tracks: int,
    flags: dict[str, bool],
    expected: str,
) -> None:
    for parse in _apple_paths(apple):
        assert parse(_apple_raw(name, tracks, **flags)).album_type == expected
