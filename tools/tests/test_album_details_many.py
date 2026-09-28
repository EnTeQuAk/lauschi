"""Batched album details: the prefetch path of a curate run.

album_details_many must hand back exactly what album_details would, per
id, while asking the provider in chunks. It shares album_details' cache
key, so an id fetched in a batch answers a later single lookup (the
agents' get_album_details tool) from cache, and a gone id is cached as
gone for both paths.
"""

from __future__ import annotations

import time
from unittest.mock import MagicMock

import pytest
import requests

from lauschi_catalog.providers import apple_music as am_mod
from lauschi_catalog.providers import spotify as spotify_mod
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.spotify import SpotifyProvider


def _response(status: int, body: dict) -> MagicMock:
    r = MagicMock(spec=requests.Response)
    r.status_code = status
    r.headers = {}
    r.json = MagicMock(return_value=body)
    if status >= 400:
        err_response = MagicMock(spec=requests.Response)
        err_response.status_code = status
        r.raise_for_status = MagicMock(
            side_effect=requests.HTTPError(f"{status}", response=err_response)
        )
    else:
        r.raise_for_status = MagicMock()
    return r


def _spotify_row(album_id: str) -> dict:
    return {
        "id": album_id,
        "name": f"Folge {album_id}",
        "images": [],
        "tracks": {"items": [{"name": f"{album_id} - Teil 1", "duration_ms": 1000}]},
    }


def _apple_row(album_id: str) -> dict:
    return {
        "id": album_id,
        "attributes": {"name": f"Folge {album_id}", "trackCount": 1},
        "relationships": {
            "tracks": {
                "data": [
                    {
                        "attributes": {
                            "name": f"{album_id} - Teil 1",
                            "durationInMillis": 1000,
                        }
                    }
                ]
            }
        },
    }


@pytest.fixture
def spotify(tmp_path, monkeypatch) -> SpotifyProvider:
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "sec")
    monkeypatch.setattr(spotify_mod, "CACHE_DIR", tmp_path / "spotify-cache")
    monkeypatch.setattr(SpotifyProvider, "_fetch_token", lambda self: "tok")
    monkeypatch.setattr(time, "sleep", lambda s: None)
    return SpotifyProvider(use_cache=True)


@pytest.fixture
def apple(tmp_path, monkeypatch) -> AppleMusicProvider:
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
    monkeypatch.setattr(am_mod, "CACHE_DIR", tmp_path / "am-cache")
    monkeypatch.setattr(time, "sleep", lambda s: None)
    return AppleMusicProvider(use_cache=True)


def _spotify_batch_server(monkeypatch, gone: frozenset[str] = frozenset()) -> list:
    """Answer /albums?ids= like Spotify: a null slot for an unknown id."""
    calls: list = []

    def fake_get(url, headers=None, params=None, timeout=None):
        calls.append((url, params))
        ids = params["ids"].split(",")
        return _response(
            200, {"albums": [None if i in gone else _spotify_row(i) for i in ids]}
        )

    monkeypatch.setattr(requests, "get", fake_get)
    return calls


def test_spotify_fetches_in_chunks_of_twenty_with_tracks(spotify, monkeypatch):
    calls = _spotify_batch_server(monkeypatch)
    ids = [f"s{i}" for i in range(45)]

    details = spotify.album_details_many(ids)

    assert len(calls) == 3
    assert sorted(details) == sorted(ids)
    assert [t.name for t in details["s7"].tracks] == ["s7 - Teil 1"]
    assert details["s7"] == spotify._album_from_details(_spotify_row("s7"))


def test_batched_ids_answer_a_later_single_lookup_from_cache(spotify, monkeypatch):
    calls = _spotify_batch_server(monkeypatch)
    spotify.album_details_many(["a1", "a2"])
    before = len(calls)

    single = spotify.album_details("a2")

    assert len(calls) == before
    assert single is not None and [t.name for t in single.tracks] == ["a2 - Teil 1"]


def test_cached_ids_are_not_requested_again(spotify, monkeypatch):
    calls = _spotify_batch_server(monkeypatch)
    spotify.album_details_many(["a1"])

    spotify.album_details_many(["a1", "a2"])

    assert calls[-1][1]["ids"] == "a2"


def test_gone_id_is_absent_and_cached_as_gone_for_single_lookups(spotify, monkeypatch):
    calls = _spotify_batch_server(monkeypatch, gone=frozenset({"dead"}))

    details = spotify.album_details_many(["a1", "dead"])

    assert sorted(details) == ["a1"]
    before = len(calls)
    assert spotify.album_details("dead") is None
    assert len(calls) == before


def test_failing_chunk_falls_back_to_single_lookups(spotify, monkeypatch):
    singles: list[str] = []

    def fake_get(url, headers=None, params=None, timeout=None):
        if params and "ids" in params:
            return _response(400, {})
        album_id = url.rsplit("/", 1)[-1]
        singles.append(album_id)
        return _response(200, _spotify_row(album_id))

    monkeypatch.setattr(requests, "get", fake_get)

    details = spotify.album_details_many(["a1", "a2"])

    assert sorted(details) == ["a1", "a2"]
    assert sorted(singles) == ["a1", "a2"]


def test_no_cache_run_still_batches_and_writes_nothing(spotify, monkeypatch):
    spotify._use_cache = False
    calls = _spotify_batch_server(monkeypatch)

    details = spotify.album_details_many(["a1", "a2"])

    assert len(calls) == 1 and sorted(details) == ["a1", "a2"]
    assert spotify._cache.get("album:a1") is None


def test_apple_requests_tracks_and_matches_album_details(apple, monkeypatch):
    calls: list = []

    def fake_get(url, headers=None, params=None, timeout=None):
        calls.append(params)
        ids = params["ids"].split(",")
        return _response(200, {"data": [_apple_row(i) for i in ids if i != "gone"]})

    monkeypatch.setattr(requests, "get", fake_get)

    details = apple.album_details_many(["m1", "gone"])

    assert calls[0]["include"] == "tracks"
    assert sorted(details) == ["m1"]
    assert [t.name for t in details["m1"].tracks] == ["m1 - Teil 1"]
    before = len(calls)
    assert apple.album_details("m1") == details["m1"]
    assert apple.album_details("gone") is None
    assert len(calls) == before
