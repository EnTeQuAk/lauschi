"""Series with multiple artist IDs per provider (e.g. a trio whose
albums are credited to every member) fetch the same album once per
artist page. The discovery list must dedupe by (provider, id) or the
batches see the same album several times.
"""

from __future__ import annotations

from lauschi_catalog.catalog.curate_ops import _dedupe_albums


def _album(provider: str, album_id: str, name: str = "x") -> dict:
    return {"provider": provider, "id": album_id, "name": name}


def test_drops_same_album_from_second_artist_page():
    albums = [
        _album("spotify", "a1", "Die 30 besten Kinderlieder"),
        _album("spotify", "a2"),
        _album("spotify", "a1", "Die 30 besten Kinderlieder"),
        _album("spotify", "a1", "Die 30 besten Kinderlieder"),
    ]
    deduped = _dedupe_albums(albums)
    assert [a["id"] for a in deduped] == ["a1", "a2"]


def test_same_id_on_different_providers_is_kept():
    albums = [_album("spotify", "a1"), _album("apple_music", "a1")]
    assert len(_dedupe_albums(albums)) == 2


def test_preserves_order():
    albums = [_album("spotify", str(i)) for i in range(5)]
    assert _dedupe_albums(albums) == albums
