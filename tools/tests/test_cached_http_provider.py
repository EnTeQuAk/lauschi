"""Recorded-response tests for the shared CachedHttpProvider machinery.

The retry loop is the part of a provider you cannot inspect without a
scripted HTTP layer: 429 must honor Retry-After, 401 must rotate the
token and retry, and a 5xx must back off and succeed. The 404 sentinel
pins that a gone album is fetched once, then answered from cache
instead of re-requested on every run.
"""

from __future__ import annotations

import time
from unittest.mock import MagicMock

import requests

from lauschi_catalog.providers import apple_music as am_mod
from lauschi_catalog.providers import spotify as spotify_mod
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.base import _NOT_FOUND
from lauschi_catalog.providers.spotify import SpotifyProvider


def _response(status: int, body: dict, headers: dict | None = None):
    r = MagicMock(spec=requests.Response)
    r.status_code = status
    r.headers = headers or {}
    r.json = MagicMock(return_value=body)
    r.raise_for_status = MagicMock(
        side_effect=None if status < 400 else requests.HTTPError(f"{status}")
    )
    r.raise_for_status.__name__ = "raise_for_status"
    if status >= 400:
        # requests' HTTPError carries .response for the 404 checks
        r.raise_for_status = MagicMock(side_effect=_make_http_error(status))
    return r


def _make_http_error(status: int) -> requests.HTTPError:
    response = MagicMock(spec=requests.Response)
    response.status_code = status
    return requests.HTTPError(f"{status} error", response=response)


def _spotify(provider_cls, tmp_path, monkeypatch):
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "sec")
    monkeypatch.setattr(spotify_mod, "CACHE_DIR", tmp_path / "spotify-cache")
    monkeypatch.setattr(
        provider_cls, "_fetch_token", lambda self: f"token-{time.time()}"
    )
    return provider_cls(use_cache=True)


def test_spotify_429_retries_with_retry_after_and_succeeds(tmp_path, monkeypatch):
    provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
    calls = {"n": 0}
    sleeps: list[float | None] = []
    monkeypatch.setattr(time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _response(429, {}, {"Retry-After": "3"})
        return _response(200, {"id": "a1"})

    monkeypatch.setattr(requests, "get", fake_get)
    assert provider._get("albums/a1") == {"id": "a1"}
    assert calls["n"] == 2
    assert 3.0 in sleeps  # the server's hint, not the default


def test_spotify_401_refreshes_token_and_retries(tmp_path, monkeypatch):
    provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
    calls = {"n": 0}
    refreshes = {"n": 0}

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _response(401, {})
        return _response(200, {"id": "a1"})

    monkeypatch.setattr(requests, "get", fake_get)
    expected_token = f"rotated-{time.time()}"

    def refresh(self):
        refreshes["n"] += 1
        return expected_token

    monkeypatch.setattr(SpotifyProvider, "_fetch_token", refresh)
    assert provider._get("albums/a1") == {"id": "a1"}
    assert refreshes["n"] == 1
    assert provider._token == expected_token


def test_spotify_5xx_backs_off_then_succeeds(tmp_path, monkeypatch):
    provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
    calls = {"n": 0}
    sleeps: list[float] = []
    monkeypatch.setattr(time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _response(503, {})
        return _response(200, {"id": "a1"})

    monkeypatch.setattr(requests, "get", fake_get)
    assert provider._get("albums/a1") == {"id": "a1"}
    assert calls["n"] == 2
    assert len(sleeps) == 1  # exponential backoff, 2 * 2**0


def test_apple_429_retries_with_retry_after_and_succeeds(tmp_path, monkeypatch):
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
    monkeypatch.setattr(am_mod, "CACHE_DIR", tmp_path / "am-cache")
    provider = AppleMusicProvider(use_cache=True)
    calls = {"n": 0}
    sleeps: list[float] = []
    monkeypatch.setattr(time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _response(429, {}, {"Retry-After": "2.5"})
        return _response(200, {"data": [{"id": "a1", "attributes": {}}]})

    monkeypatch.setattr(requests, "get", fake_get)
    assert provider._get("albums/a1")["data"][0]["id"] == "a1"
    assert calls["n"] == 2
    assert 2.5 in sleeps


def test_apple_401_rotates_token_and_retries(tmp_path, monkeypatch):
    monkeypatch.setattr(am_mod, "CACHE_DIR", tmp_path / "am-cache")
    tokens = iter(["dead-token", "fresh-token"])
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: next(tokens))
    provider = AppleMusicProvider(use_cache=True)
    calls = {"n": 0}

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if headers and "Authorization" in headers:
            if headers["Authorization"] == "Bearer dead-token":
                return _response(401, {})
        return _response(200, {"data": [{"id": "a1", "attributes": {}}]})

    monkeypatch.setattr(requests, "get", fake_get)
    assert provider._get("albums/a1")["data"][0]["id"] == "a1"
    assert provider._token == "fresh-token"


def test_apple_5xx_backs_off_then_succeeds(tmp_path, monkeypatch):
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
    monkeypatch.setattr(am_mod, "CACHE_DIR", tmp_path / "am-cache")
    provider = AppleMusicProvider(use_cache=True)
    calls = {"n": 0}
    sleeps: list[float] = []
    monkeypatch.setattr(time, "sleep", lambda s: sleeps.append(s))

    def fake_get(url, headers=None, params=None, timeout=None):
        calls["n"] += 1
        if calls["n"] == 1:
            return _response(504, {})
        return _response(200, {"data": [{"id": "a1", "attributes": {}}]})

    monkeypatch.setattr(requests, "get", fake_get)
    assert provider._get("albums/a1")["data"][0]["id"] == "a1"
    assert len(sleeps) == 1


class TestNotFoundSentinel:
    def test_spotify_gone_album_answered_from_cache(self, tmp_path, monkeypatch):
        provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
        calls = {"n": 0}

        def fake_get(url, headers=None, params=None, timeout=None):
            calls["n"] += 1
            # A batch of one gone album: the API returns the id's slot null.
            return _response(200, {"albums": [None]})

        monkeypatch.setattr(requests, "get", fake_get)
        batch = provider.albums_by_ids(["gone1"])
        assert batch.albums == []
        assert batch.unverified == []
        assert provider._cache.get("spotify:albums:gone1") == _NOT_FOUND

        before = calls["n"]
        second = provider.albums_by_ids(["gone1"])
        assert calls["n"] == before  # no network
        assert second.albums == []
        assert second.unverified == []

    def test_spotify_known_album_cached_per_id(self, tmp_path, monkeypatch):
        provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
        calls = {"n": 0}

        def fake_get(url, headers=None, params=None, timeout=None):
            calls["n"] += 1
            return _response(
                200,
                {"albums": [{"id": "x1", "name": "Album", "images": []}]},
            )

        monkeypatch.setattr(requests, "get", fake_get)
        batch = provider.albums_by_ids(["x1"])
        assert [a.id for a in batch.albums] == ["x1"]
        row = provider._cache.get("spotify:albums:x1")
        assert isinstance(row, dict)

        before = calls["n"]
        second = provider.albums_by_ids(["x1"])
        assert calls["n"] == before
        assert [a.id for a in second.albums] == ["x1"]

    def test_spotify_single_gone_album_does_not_recheck_on_details(
        self, tmp_path, monkeypatch
    ):
        provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
        calls = {"n": 0}

        def fake_get(url, headers=None, params=None, timeout=None):
            calls["n"] += 1
            return _response(404, {})

        monkeypatch.setattr(requests, "get", fake_get)
        assert provider.album_details("gone9") is None
        assert provider.album_details("gone9") is None
        assert calls["n"] == 1  # second call answered from the cache

    def test_apple_gone_album_answered_from_cache(self, tmp_path, monkeypatch):
        monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
        monkeypatch.setattr(am_mod, "CACHE_DIR", tmp_path / "am-cache")
        provider = AppleMusicProvider(use_cache=True)
        calls = {"n": 0}

        def fake_get(url, headers=None, params=None, timeout=None):
            calls["n"] += 1
            return _response(200, {"data": []})

        monkeypatch.setattr(requests, "get", fake_get)
        batch = provider.albums_by_ids(["gone1"])
        assert batch.albums == []
        assert batch.unverified == []
        assert provider._cache.get("apple_music:albums:gone1") == _NOT_FOUND

        before = calls["n"]
        provider.albums_by_ids(["gone1"])
        assert calls["n"] == before

    def test_no_cache_run_writes_nothing(self, tmp_path, monkeypatch):
        provider = _spotify(SpotifyProvider, tmp_path, monkeypatch)
        provider._use_cache = False

        def fake_get(url, headers=None, params=None, timeout=None):
            return _response(
                200, {"albums": [{"id": "x1", "name": "Album", "images": []}]}
            )

        monkeypatch.setattr(requests, "get", fake_get)
        provider.albums_by_ids(["x1"])
        # a no-cache run must not leave batch rows behind
        assert provider._cache.get("spotify:albums:x1") is None
