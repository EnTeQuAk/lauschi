"""Regression tests for SpotifyProvider.artist_albums group filtering.

The endpoint's filter parameter is ``include_groups``; the provider
previously sent ``album_type`` which Spotify silently ignores, so
``appears_on`` albums (other artists' releases the artist features on)
flooded every discography — 31% of all cached albums were appears_on,
and several music-series curations included foreign compilation albums.
See https://developer.spotify.com/documentation/web-api/reference/get-an-artists-albums
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import requests

from lauschi_catalog.providers.spotify import SpotifyProvider


@pytest.fixture
def provider(monkeypatch):
    monkeypatch.setenv("SPOTIFY_CLIENT_ID", "test-id")
    monkeypatch.setenv("SPOTIFY_CLIENT_SECRET", "test-secret")
    monkeypatch.setattr(SpotifyProvider, "_fetch_token", lambda self: "test-token")
    return SpotifyProvider(use_cache=False)


def _album_item(album_id: str, name: str, group: str) -> dict:
    return {
        "id": album_id,
        "name": name,
        "album_group": group,
        "album_type": "album" if group != "appears_on" else "compilation",
        "release_date": "2024-01-01",
        "total_tracks": 12,
        "images": [],
    }


def _make_response(json_data: dict):
    r = MagicMock(spec=requests.Response)
    r.status_code = 200
    r.headers = {}
    r.json = MagicMock(return_value=json_data)
    r.raise_for_status = MagicMock(return_value=None)
    return r


def test_requests_include_groups_param(provider, monkeypatch):
    """The Spotify filter param is include_groups; album_type is only a
    response field and gets silently ignored as a query param."""
    captured: dict = {}

    def fake_get(url, *, headers=None, params=None, timeout=None):
        captured["params"] = params or {}
        return _make_response({"items": [], "next": None})

    monkeypatch.setattr(requests, "get", fake_get)
    provider.artist_albums("artist123")

    assert captured["params"].get("include_groups") == "album,single,compilation"
    assert "album_type" not in captured["params"]


def test_filters_appears_on_items(provider, monkeypatch):
    """Safety net for stale cache entries fetched before the param fix:
    appears_on items are dropped even if present in the response."""
    items = [
        _album_item("own1", "Folge 1: Eigenes Album", "album"),
        _album_item("foreign1", "Kinderlieder Fasching 2026", "appears_on"),
        _album_item("own2", "Eigene Single", "single"),
    ]

    def fake_get(url, *, headers=None, params=None, timeout=None):
        return _make_response({"items": items, "next": None})

    monkeypatch.setattr(requests, "get", fake_get)
    albums = provider.artist_albums("artist123")

    assert [a.id for a in albums] == ["own1", "own2"]
