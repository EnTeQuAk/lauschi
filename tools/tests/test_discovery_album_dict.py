"""The discovery loop converts provider Albums to dicts that feed the
curate batch prompt. album_type (album/single/compilation) must survive
the conversion: it lets the batch agent tell artist-own primary albums
from repackaged compilations, which matters for artists whose primary
releases carry compilation-sounding titles (e.g. "Die 30 besten ...").
"""

from __future__ import annotations

from lauschi_catalog.catalog.curate_ops import _discovery_album_dict
from lauschi_catalog.providers.base import Album


def test_carries_album_type():
    album = Album(
        id="abc123",
        name="Die 30 besten Spiel- und Bewegungslieder",
        provider="spotify",
        release_date="2010-08-13",
        total_tracks=30,
        album_type="album",
        image_url="https://img/1.jpg",
    )
    d = _discovery_album_dict("spotify", album)
    assert d == {
        "provider": "spotify",
        "id": "abc123",
        "name": "Die 30 besten Spiel- und Bewegungslieder",
        "release_date": "2010-08-13",
        "total_tracks": 30,
        "album_type": "album",
        "image_url": "https://img/1.jpg",
    }


def test_album_type_defaults_empty():
    """Apple Music doesn't classify albums; the field stays empty."""
    album = Album(id="1", name="X", provider="apple_music")
    d = _discovery_album_dict("apple_music", album)
    assert d["album_type"] == ""
