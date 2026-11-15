"""Tests for catalog.album_ops module."""

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
            {
                "album_id": "alb2",
                "include": False,
                "exclude_reason": "compilation",
                "title": "Best Of",
            },
        ],
    }
    (curation_dir / "test_series.json").write_text(json.dumps(curation))

    monkeypatch.setattr(
        album_ops, "curation_path", lambda sid: curation_dir / f"{sid}.json"
    )
    return curation_dir


class TestUpdateAlbum:
    def test_exclude_album(self, album_env):
        result = album_ops.update_album(
            "test_series",
            "alb1",
            include=False,
            exclude_reason="music_single",
        )
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["include"] is False
        assert alb["exclude_reason"] == "music_single"

    def test_include_album_clears_reason(self, album_env):
        result = album_ops.update_album("test_series", "alb2", include=True)
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb2")
        assert alb["include"] is True
        assert "exclude_reason" not in alb

    def test_nonexistent_album(self, album_env):
        result = album_ops.update_album("test_series", "no_such_album", include=True)
        assert not result.ok
        assert "album not found" in result.error

    def test_update_episode_num(self, album_env):
        result = album_ops.update_album("test_series", "alb1", episode_num=42)
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["episode_num"] == 42

    def test_update_title(self, album_env):
        result = album_ops.update_album("test_series", "alb1", title="New Title")
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["title"] == "New Title"

    def test_update_fields_without_include(self, album_env):
        result = album_ops.update_album(
            "test_series", "alb1", episode_num=7, title="Renamed"
        )
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["episode_num"] == 7
        assert alb["title"] == "Renamed"
        assert alb["include"] is True

    def test_nonexistent_curation(self, album_env):
        result = album_ops.update_album("no_such_series", "alb1", include=True)
        assert not result.ok
        assert "curation not found" in result.error

    @pytest.mark.parametrize(
        "change",
        [
            {"include": False, "exclude_reason": "music_single"},
            {"episode_num": 3},
            {"title": "Renamed"},
        ],
        ids=["exclude", "number", "title"],
    )
    def test_a_change_is_recorded_as_a_persons_decision(self, album_env, change):
        """The web UI saves a person's edits here. Recorded as theirs, a
        re-curate keeps them and an audit leaves them alone, as it does
        for `lauschi-catalog edit`."""
        result = album_ops.update_album("test_series", "alb1", **change)
        assert result.ok
        data = json.loads((album_env / "test_series.json").read_text())
        alb = next(a for a in data["albums"] if a["album_id"] == "alb1")
        assert alb["decided_by"] == "operator"
        assert alb["decided_at"]
