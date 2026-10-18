"""Spotify album records keep their artist names.

They came without them, so the curator saw no `<artist>` for any Spotify
album while Apple Music showed its credit, and the reference QA had
credits from Apple Music only.
"""

import pytest

from lauschi_catalog.providers.spotify import SpotifyProvider


@pytest.fixture
def spotify(monkeypatch: pytest.MonkeyPatch) -> SpotifyProvider:
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "sec")
    monkeypatch.setattr(SpotifyProvider, "_fetch_token", lambda self: "tok")
    return SpotifyProvider(use_cache=False)


RAW = {
    "id": "s1",
    "name": "Folge 1: Der Sturm",
    "album_type": "album",
    "total_tracks": 12,
    "release_date": "2014-03-07",
    "artists": [{"name": "Dragons - Die Reiter von Berk"}, {"name": "Trolljäger"}],
    "images": [],
    "tracks": {"items": []},
}


def test_every_spotify_album_record_keeps_its_artist_names(
    spotify: SpotifyProvider,
) -> None:
    spotify._cached = lambda key, fetch: [RAW]  # type: ignore[method-assign]
    for album in (
        spotify._album_from_details(RAW),
        spotify.raw_to_album(RAW),
        spotify.artist_albums("artist")[0],
    ):
        assert album.artists == "Dragons - Die Reiter von Berk, Trolljäger"
