"""Regression tests for SpotifyProvider._fetch_token retry.

A 26-entry catalog loop lost 21 entries to a single Spotify wobble
(initial ReadTimeout, then 503 Service Unavailable on
accounts.spotify.com/api/token) because the provider's token-fetch
had no retry — it crashed __init__ on the first transient and every
dependent command died with it. These tests pin both failure modes.
"""

from __future__ import annotations

import time
from unittest.mock import MagicMock

import pytest
import requests

from lauschi_catalog.providers.spotify import SpotifyProvider


@pytest.fixture
def fake_credentials(monkeypatch):
    """SpotifyProvider.__init__ reads creds from env and immediately
    fetches a token. Set both unconditionally so the test path is
    deterministic regardless of host env."""
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "test-id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "test-secret")


@pytest.fixture
def no_sleep(monkeypatch):
    """Don't actually wait 1-4 seconds in tests."""
    monkeypatch.setattr(time, "sleep", lambda _s: None)


def _make_response(status: int, json_data: dict | None = None, headers: dict | None = None):
    r = MagicMock(spec=requests.Response)
    r.status_code = status
    r.headers = headers or {}
    r.json = MagicMock(return_value=json_data or {})
    if status >= 400:
        err = requests.HTTPError(f"{status}", response=r)
        r.raise_for_status = MagicMock(side_effect=err)
    else:
        r.raise_for_status = MagicMock(return_value=None)
    return r


# ── transient HTTP 5xx ────────────────────────────────────────────────────


def test_retries_on_503_and_succeeds(fake_credentials, no_sleep, monkeypatch):
    """The actual failure mode from the catalog loop: 503 on first
    attempt, success on second. Without retry, the provider can't
    even be constructed."""
    calls: list[MagicMock] = []
    def fake_post(url, **kwargs):
        calls.append(MagicMock(url=url, kwargs=kwargs))
        if len(calls) == 1:
            return _make_response(503)
        return _make_response(200, {"access_token": "tok-after-retry"})
    monkeypatch.setattr("requests.post", fake_post)

    p = SpotifyProvider(use_cache=False)
    assert p._token == "tok-after-retry"
    assert len(calls) == 2


def test_gives_up_after_five_5xx(fake_credentials, no_sleep, monkeypatch):
    """If Spotify is genuinely down for all five attempts, raise
    a clear HTTPError. Don't loop forever and don't swallow the
    error silently.

    Five attempts (2+4+8+16+32s sleeps = 62s total) cover a
    roughly-one-minute outage. After that, surface the failure.
    """
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        return _make_response(503)
    monkeypatch.setattr("requests.post", fake_post)
    with pytest.raises(requests.HTTPError):
        SpotifyProvider(use_cache=False)
    assert len(calls) == 5


# ── transient network errors ──────────────────────────────────────────────


def test_retries_on_read_timeout_and_succeeds(fake_credentials, no_sleep, monkeypatch):
    """The other failure seen in the catalog loop — a ReadTimeout
    against accounts.spotify.com. Same retry-and-recover path."""
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        if len(calls) == 1:
            raise requests.Timeout("read timed out")
        return _make_response(200, {"access_token": "tok-after-timeout"})
    monkeypatch.setattr("requests.post", fake_post)

    p = SpotifyProvider(use_cache=False)
    assert p._token == "tok-after-timeout"
    assert len(calls) == 2


def test_retries_on_connection_error(fake_credentials, no_sleep, monkeypatch):
    """DNS hiccup or connection refused — also transient."""
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        if len(calls) == 1:
            raise requests.ConnectionError("connection refused")
        return _make_response(200, {"access_token": "tok"})
    monkeypatch.setattr("requests.post", fake_post)
    p = SpotifyProvider(use_cache=False)
    assert p._token == "tok"


def test_propagates_timeout_after_five_attempts(fake_credentials, no_sleep, monkeypatch):
    """A genuinely-down network surfaces as the original exception
    so the caller can log it clearly."""
    calls = []
    def always_timeout(*a, **kw):
        calls.append(1)
        raise requests.Timeout("perpetual timeout")
    monkeypatch.setattr("requests.post", always_timeout)
    with pytest.raises(requests.Timeout):
        SpotifyProvider(use_cache=False)
    assert len(calls) == 5


# ── 429 honors Retry-After ────────────────────────────────────────────────


def test_retries_on_429_honoring_retry_after(fake_credentials, no_sleep, monkeypatch):
    """The existing _get path honors Retry-After on 429; the token
    fetch should too, for consistency."""
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        if len(calls) == 1:
            return _make_response(429, headers={"Retry-After": "1"})
        return _make_response(200, {"access_token": "tok"})
    monkeypatch.setattr("requests.post", fake_post)
    p = SpotifyProvider(use_cache=False)
    assert p._token == "tok"


# ── 4xx errors fail fast (no retry) ───────────────────────────────────────


def test_does_not_retry_on_401(fake_credentials, no_sleep, monkeypatch):
    """Bad client credentials won't fix themselves on retry. Fail
    fast so the user sees the misconfig immediately rather than
    after three retries."""
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        return _make_response(401)
    monkeypatch.setattr("requests.post", fake_post)
    with pytest.raises(requests.HTTPError):
        SpotifyProvider(use_cache=False)
    assert len(calls) == 1  # exactly one attempt


def test_does_not_retry_on_400(fake_credentials, no_sleep, monkeypatch):
    calls = []
    def fake_post(*a, **kw):
        calls.append(1)
        return _make_response(400)
    monkeypatch.setattr("requests.post", fake_post)
    with pytest.raises(requests.HTTPError):
        SpotifyProvider(use_cache=False)
    assert len(calls) == 1
