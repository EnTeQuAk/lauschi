"""Regression tests for AppleMusicProvider.artist_albums view fetching.

The artist `albums` relationship includes albums where the artist is
only feature-credited: Simone Sommerland's page returned 728 albums of
which 600 were "… für [Name] (feat. Simone Sommerland)" releases by the
"Kinderlied für dich" brand family. The artist views full-albums,
singles, and compilation-albums return only the artist's own releases;
appears-on-albums isolates the feature credits and is not fetched.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import requests

from lauschi_catalog.providers.apple_music import AppleMusicProvider


def _album_resource(album_id: str, name: str, artist: str) -> dict:
    return {
        "id": album_id,
        "attributes": {
            "name": name,
            "artistName": artist,
            "releaseDate": "2020-01-01",
            "trackCount": 30,
        },
    }


def _http_404(url: str) -> requests.HTTPError:
    r = MagicMock(spec=requests.Response)
    r.status_code = 404
    return requests.HTTPError(f"404 Client Error: Not Found for url: {url}", response=r)


@pytest.fixture
def provider(monkeypatch):
    monkeypatch.setattr(AppleMusicProvider, "_generate_token", lambda *a: "tok")
    return AppleMusicProvider(use_cache=False)


def test_fetches_own_release_views_not_albums_relationship(provider, monkeypatch):
    def fake_request(self, url, *, params=None):
        if "/view/full-albums" in url:
            if "page2" in url:
                return {"data": [_album_resource("a3", "Album 3", "Trio")]}
            return {
                "data": [
                    _album_resource("a1", "Die 30 besten Kinderlieder", "Trio"),
                    _album_resource("a2", "Album 2", "Trio"),
                ],
                "next": "/v1/catalog/de/artists/x/view/full-albums?page2",
            }
        if "/view/singles" in url:
            return {"data": [_album_resource("s1", "Blinde Kuh - Single", "Trio")]}
        if "/view/compilation-albums" in url:
            return {"data": [_album_resource("c1", "Die 100 besten Winterlieder", "Trio")]}
        if "/view/live-albums" in url:
            raise _http_404(url)
        raise AssertionError(f"unexpected URL fetched: {url}")

    monkeypatch.setattr(AppleMusicProvider, "_request", fake_request)
    albums = provider.artist_albums("397732566")

    assert [a.id for a in albums] == ["a1", "a2", "a3", "s1", "c1"]
    assert albums[0].name == "Die 30 besten Kinderlieder"


def test_album_in_multiple_views_appears_once(provider, monkeypatch):
    shared = _album_resource("dup", "Die 30 besten Partylieder", "Trio")

    def fake_request(self, url, *, params=None):
        if "/view/full-albums" in url or "/view/compilation-albums" in url:
            return {"data": [shared]}
        return {"data": []}

    monkeypatch.setattr(AppleMusicProvider, "_request", fake_request)
    albums = provider.artist_albums("397732566")
    assert [a.id for a in albums] == ["dup"]


def test_missing_view_is_skipped(provider, monkeypatch):
    """Artists without live albums 404 on that view; other views still load."""
    def fake_request(self, url, *, params=None):
        if "/view/full-albums" in url:
            return {"data": [_album_resource("a1", "Album", "Trio")]}
        raise _http_404(url)

    monkeypatch.setattr(AppleMusicProvider, "_request", fake_request)
    albums = provider.artist_albums("397732566")
    assert [a.id for a in albums] == ["a1"]
