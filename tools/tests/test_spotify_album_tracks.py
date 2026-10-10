"""Spotify album details carry every track.

The album endpoints embed the first 50 tracks and link the rest. The
provider kept only the embedded ones, so an album with more tracks
reached the curator with a cut track list and a running time summed over
the first 50: "Das Sams 4" has 83 tracks and showed 164 minutes instead
of 269. The running time is what tells a reading from a Hörspiel of the
same title.
See https://developer.spotify.com/documentation/web-api/reference/get-an-album
"""

from pathlib import Path
from unittest.mock import MagicMock

import pytest
import requests

from lauschi_catalog.providers.spotify import SpotifyProvider

NEXT = "https://api.spotify.com/v1/albums/long/tracks?offset=50&limit=50"


def _tracks(first: int, count: int) -> list[dict]:
    return [
        {"name": f"Kapitel {n}", "duration_ms": 60_000}
        for n in range(first, first + count)
    ]


def _album(album_id: str, total: int) -> dict:
    return {
        "id": album_id,
        "name": f"Album {album_id}",
        "album_type": "album",
        "release_date": "2018-10-22",
        "total_tracks": total,
        "images": [],
        "tracks": {
            "items": _tracks(1, min(total, 50)),
            "next": NEXT if total > 50 else None,
            "total": total,
        },
    }


class _Spotify:
    """The album endpoints of the web API, counting what is asked."""

    def __init__(self) -> None:
        self.asked: list[str] = []

    def get(
        self,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        params: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> MagicMock:
        self.asked.append(url)
        if url == NEXT:
            data = {"items": _tracks(51, 33), "next": None}
        elif url.endswith("/albums"):
            ids = (params or {})["ids"].split(",")
            data = {"albums": [_album(i, 83 if i == "long" else 12) for i in ids]}
        else:
            album_id = url.rsplit("/", 1)[-1]
            data = _album(album_id, 83 if album_id == "long" else 12)
        response = MagicMock(spec=requests.Response)
        response.status_code = 200
        response.headers = {}
        response.json = MagicMock(return_value=data)
        response.raise_for_status = MagicMock(return_value=None)
        return response


@pytest.fixture
def spotify(monkeypatch: pytest.MonkeyPatch) -> _Spotify:
    api = _Spotify()
    monkeypatch.setattr(requests, "get", api.get)
    monkeypatch.setattr("time.sleep", lambda _s: None)
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "test-id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "test-secret")
    monkeypatch.setattr(SpotifyProvider, "_fetch_token", lambda self: "test-token")
    return api


def test_a_long_album_comes_with_all_its_tracks(spotify: _Spotify) -> None:
    album = SpotifyProvider(use_cache=False).album_details("long")

    assert album is not None
    assert len(album.tracks) == album.total_tracks == 83
    assert album.tracks[-1].name == "Kapitel 83"
    assert sum(t.duration_ms for t in album.tracks) == 83 * 60_000


def test_the_batched_lookup_pages_through_long_albums_too(spotify: _Spotify) -> None:
    albums = SpotifyProvider(use_cache=False).album_details_many(["short", "long"])

    assert len(albums["long"].tracks) == 83
    assert len(albums["short"].tracks) == 12
    assert spotify.asked.count(NEXT) == 1


def test_an_album_of_up_to_fifty_tracks_needs_one_request(spotify: _Spotify) -> None:
    SpotifyProvider(use_cache=False).album_details("short")

    assert spotify.asked == ["https://api.spotify.com/v1/albums/short"]


def test_a_cut_album_in_the_cache_is_completed_once(
    spotify: _Spotify, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The cache holds albums fetched with the first 50 tracks only. They
    are completed when read, and the complete album is what stays cached."""
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    provider = SpotifyProvider()
    provider._cache.set("album:long", _album("long", 83))

    first = provider.album_details_many(["long"])["long"]
    again = provider.album_details("long")

    assert len(first.tracks) == 83
    assert again is not None and len(again.tracks) == 83
    assert spotify.asked == [NEXT]
