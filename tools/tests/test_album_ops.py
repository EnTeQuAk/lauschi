"""Tests for catalog.album_ops module."""

from __future__ import annotations

import json

import pytest

from lauschi_catalog.catalog import album_ops


@pytest.fixture
def album_env(monkeypatch, tmp_path):
    """A curation file with albums."""
    curation_dir = tmp_path / "curation"
    curation_dir.mkdir()

    curation = {
        "id": "test_series",
        "albums": [
            {"album_id": "alb1", "include": True, "title": "Episode 1"},
            {"album_id": "alb2", "include": False, "exclude_reason": "compilation", "title": "Best Of"},
        ],
    }
    (curation_dir / "test_series.json").write_text(json.dumps(curation))

    monkeypatch.setattr(album_ops, "curation_path", lambda sid: curation_dir / f"{sid}.json")
    return curation_dir


class TestUpdateAlbumStatus:
    def test_exclude_album(self, album_env):
        result = album_ops.update_album_status(
            "test_series", "alb1", include=False, exclude_reason="music_single",
        )
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["include"] is False
        assert alb["exclude_reason"] == "music_single"

    def test_include_album_clears_reason(self, album_env):
        result = album_ops.update_album_status("test_series", "alb2", include=True)
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb2")
        assert alb["include"] is True
        assert "exclude_reason" not in alb

    def test_nonexistent_album(self, album_env):
        result = album_ops.update_album_status("test_series", "no_such_album", include=True)
        assert not result.ok
        assert "album not found" in result.error

    def test_nonexistent_curation(self, album_env):
        result = album_ops.update_album_status("no_such_series", "alb1", include=True)
        assert not result.ok
        assert "curation not found" in result.error
