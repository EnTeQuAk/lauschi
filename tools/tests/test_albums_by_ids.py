"""Tests for the batched album lookup both providers expose.

Drift detection is only affordable because of this: 14,070 albums become
~430 requests instead of 14,070. The chunk sizes are API maxima verified
against the live services (Spotify rejects >20, Apple Music rejects
>100), so they are pinned here.

Missing IDs must be dropped rather than raising, because "absent" is a
meaningful answer: it means the album is gone.
"""

from __future__ import annotations

from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.spotify import SpotifyProvider


class _Recorder:
    """Stands in for the provider's HTTP layer."""

    def __init__(self, responder):
        self.calls: list[list[str]] = []
        self._responder = responder

    def __call__(self, path, **params):
        ids = params["ids"].split(",")
        self.calls.append(ids)
        return self._responder(ids)


def _spotify_with(responder) -> tuple[SpotifyProvider, _Recorder]:
    provider = SpotifyProvider.__new__(SpotifyProvider)
    provider._use_cache = False  # noqa: SLF001
    recorder = _Recorder(responder)
    provider._get = recorder  # type: ignore[method-assign]  # noqa: SLF001
    provider._cached = lambda _key, fetch: fetch()  # type: ignore[method-assign]  # noqa: SLF001
    return provider, recorder


def _apple_with(responder) -> tuple[AppleMusicProvider, _Recorder]:
    provider = AppleMusicProvider.__new__(AppleMusicProvider)
    provider._use_cache = False  # noqa: SLF001
    recorder = _Recorder(responder)
    provider._get = recorder  # type: ignore[method-assign]  # noqa: SLF001
    provider._cached = lambda _key, fetch: fetch()  # type: ignore[method-assign]  # noqa: SLF001
    provider._ensure_token = lambda: None  # type: ignore[method-assign]  # noqa: SLF001
    return provider, recorder


def test_spotify_chunks_at_twenty():
    provider, recorder = _spotify_with(
        lambda ids: {
            "albums": [
                {"id": i, "name": f"Album {i}", "release_date": "2020"} for i in ids
            ]
        }
    )
    albums = provider.albums_by_ids([f"id{n}" for n in range(45)])
    assert [len(c) for c in recorder.calls] == [20, 20, 5]
    assert len(albums) == 45
    assert albums[0].provider == "spotify"


def test_spotify_drops_missing_albums():
    """A null entry means Spotify no longer knows the ID."""
    provider, _ = _spotify_with(
        lambda ids: {
            "albums": [
                None if i == "gone" else {"id": i, "name": i, "release_date": "2020"}
                for i in ids
            ]
        }
    )
    albums = provider.albums_by_ids(["alive", "gone"])
    assert [a.id for a in albums] == ["alive"]


def test_apple_music_chunks_at_hundred():
    provider, recorder = _apple_with(
        lambda ids: {
            "data": [
                {"id": i, "attributes": {"name": f"Album {i}", "releaseDate": "2020"}}
                for i in ids
            ]
        }
    )
    albums = provider.albums_by_ids([f"id{n}" for n in range(250)])
    assert [len(c) for c in recorder.calls] == [100, 100, 50]
    assert len(albums) == 250
    assert albums[0].provider == "apple_music"


def test_apple_music_omits_missing_albums():
    """Apple Music leaves unknown IDs out of the response entirely."""
    provider, _ = _apple_with(
        lambda ids: {
            "data": [
                {"id": i, "attributes": {"name": i, "releaseDate": "2020"}}
                for i in ids
                if i != "gone"
            ]
        }
    )
    albums = provider.albums_by_ids(["alive", "gone"])
    assert [a.id for a in albums] == ["alive"]


def test_empty_input_makes_no_requests():
    provider, recorder = _spotify_with(lambda ids: {"albums": []})
    assert provider.albums_by_ids([]) == []
    assert recorder.calls == []
