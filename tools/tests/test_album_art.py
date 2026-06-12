"""Tests for album art data layer (image URLs and cover cache)."""

from __future__ import annotations

import json

from lauschi_catalog.providers.base import Album
from lauschi_catalog.providers.spotify import _pick_image
from lauschi_catalog.providers.apple_music import _pick_artwork
from lauschi_catalog.catalog.curate_ops import write_cover_cache


class TestSpotifyPickImage:
    def test_picks_300px_image(self):
        images = [
            {"url": "https://i.scdn.co/image/large", "width": 640, "height": 640},
            {"url": "https://i.scdn.co/image/medium", "width": 300, "height": 300},
            {"url": "https://i.scdn.co/image/small", "width": 64, "height": 64},
        ]
        assert _pick_image(images) == "https://i.scdn.co/image/medium"

    def test_picks_smallest_when_all_large(self):
        images = [
            {"url": "https://i.scdn.co/image/huge", "width": 1000, "height": 1000},
            {"url": "https://i.scdn.co/image/large", "width": 640, "height": 640},
        ]
        assert _pick_image(images) == "https://i.scdn.co/image/large"

    def test_empty_images_returns_empty(self):
        assert _pick_image([]) == ""

    def test_single_image(self):
        images = [{"url": "https://i.scdn.co/image/only", "width": 300}]
        assert _pick_image(images) == "https://i.scdn.co/image/only"


class TestAppleMusicPickArtwork:
    def test_resolves_url_template(self):
        attrs = {
            "artwork": {
                "url": "https://is1-ssl.mzstatic.com/image/{w}x{h}bb.jpg",
                "width": 3000,
                "height": 3000,
            },
        }
        result = _pick_artwork(attrs)
        assert result == "https://is1-ssl.mzstatic.com/image/300x300bb.jpg"

    def test_empty_artwork_returns_empty(self):
        assert _pick_artwork({}) == ""
        assert _pick_artwork({"artwork": {}}) == ""


class TestAlbumImageUrl:
    def test_album_has_image_url_field(self):
        album = Album(
            id="123",
            name="Test",
            provider="spotify",
            image_url="https://example.com/cover.jpg",
        )
        assert album.image_url == "https://example.com/cover.jpg"

    def test_album_image_url_defaults_empty(self):
        album = Album(id="123", name="Test", provider="spotify")
        assert album.image_url == ""


class TestWriteCoverCache:
    def test_writes_cache_from_raw_albums(self, tmp_path, monkeypatch):
        from lauschi_catalog.catalog import curate_ops as curate_ops_mod

        monkeypatch.setattr(curate_ops_mod, "cover_cache_dir", lambda: tmp_path)
        monkeypatch.setattr(
            curate_ops_mod,
            "cover_cache_path",
            lambda sid: tmp_path / f"{sid}.json",
        )

        albums = [
            {"id": "abc", "provider": "spotify", "image_url": "https://img/a"},
            {"id": "def", "provider": "spotify", "image_url": "https://img/b"},
            {"id": "ghi", "provider": "spotify", "image_url": ""},
        ]
        write_cover_cache("test_series", albums)

        cache_file = tmp_path / "test_series.json"
        assert cache_file.exists()
        data = json.loads(cache_file.read_text())
        assert data == {"abc": "https://img/a", "def": "https://img/b"}

    def test_skips_when_no_images(self, tmp_path, monkeypatch):
        from lauschi_catalog.catalog import curate_ops as curate_ops_mod

        monkeypatch.setattr(curate_ops_mod, "cover_cache_dir", lambda: tmp_path)
        monkeypatch.setattr(
            curate_ops_mod,
            "cover_cache_path",
            lambda sid: tmp_path / f"{sid}.json",
        )

        albums = [{"id": "abc", "provider": "spotify", "image_url": ""}]
        write_cover_cache("test_series", albums)
        assert not (tmp_path / "test_series.json").exists()

    def test_handles_album_id_key(self, tmp_path, monkeypatch):
        """Curation JSON uses album_id instead of id."""
        from lauschi_catalog.catalog import curate_ops as curate_ops_mod

        monkeypatch.setattr(curate_ops_mod, "cover_cache_dir", lambda: tmp_path)
        monkeypatch.setattr(
            curate_ops_mod,
            "cover_cache_path",
            lambda sid: tmp_path / f"{sid}.json",
        )

        albums = [
            {"album_id": "xyz", "provider": "spotify", "image_url": "https://img/c"},
        ]
        write_cover_cache("test_series", albums)
        data = json.loads((tmp_path / "test_series.json").read_text())
        assert data == {"xyz": "https://img/c"}
