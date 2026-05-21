"""Tests for catalog.merge_ops module."""

from __future__ import annotations

import json

import pytest
from ruamel.yaml import YAML

from lauschi_catalog.catalog import paths as paths_mod
from lauschi_catalog.catalog import loader as loader_mod
from lauschi_catalog.catalog import merge_ops

yaml = YAML()
yaml.preserve_quotes = True


@pytest.fixture
def merge_env(monkeypatch, tmp_path):
    """Two series with curations, ready to merge."""
    series_yaml = tmp_path / "series.yaml"
    curation_dir = tmp_path / "curation"
    curation_dir.mkdir()

    yaml.dump(
        {
            "series": [
                {"id": "source", "title": "Source Series", "providers": {}},
                {"id": "target", "title": "Target Series", "providers": {}},
            ],
        },
        series_yaml,
    )

    source_curation = {
        "id": "source",
        "title": "Source Series",
        "provider_artist_ids": {"spotify": ["s1"]},
        "albums": [
            {"album_id": "a1", "episode_num": 1, "provider": "spotify", "title": "Ep 1"},
            {"album_id": "a2", "episode_num": 2, "provider": "spotify", "title": "Ep 2"},
        ],
    }
    (curation_dir / "source.json").write_text(json.dumps(source_curation))

    target_curation = {
        "id": "target",
        "title": "Target Series",
        "provider_artist_ids": {"spotify": ["t1"]},
        "albums": [
            {"album_id": "a1", "episode_num": 1, "provider": "spotify", "title": "Ep 1"},
        ],
    }
    (curation_dir / "target.json").write_text(json.dumps(target_curation))

    monkeypatch.setattr(paths_mod, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(paths_mod, "series_yaml_path", lambda: series_yaml)
    monkeypatch.setattr(paths_mod, "curation_dir", lambda: curation_dir)
    monkeypatch.setattr(paths_mod, "curation_path", lambda sid: curation_dir / f"{sid}.json")
    monkeypatch.setattr(paths_mod, "series_lock_path", lambda: tmp_path / ".lock")
    monkeypatch.setattr(paths_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(loader_mod, "SERIES_YAML", series_yaml)

    return {
        "series_yaml": series_yaml,
        "curation_dir": curation_dir,
    }


class TestMergeSeries:
    def test_merge_moves_unique_albums(self, merge_env):
        result = merge_ops.merge_series("source", "target")
        assert result.ok
        assert result.added == 1  # a2 is new
        assert result.skipped == 1  # a1 already exists

    def test_merge_removes_source(self, merge_env):
        merge_ops.merge_series("source", "target")
        data = yaml.load(merge_env["series_yaml"])
        ids = [e["id"] for e in data["series"]]
        assert "source" not in ids
        assert "target" in ids

    def test_merge_deletes_source_curation(self, merge_env):
        merge_ops.merge_series("source", "target")
        assert not (merge_env["curation_dir"] / "source.json").exists()

    def test_merge_combines_provider_ids(self, merge_env):
        merge_ops.merge_series("source", "target")
        target = json.loads((merge_env["curation_dir"] / "target.json").read_text())
        spotify_ids = set(target["provider_artist_ids"]["spotify"])
        assert spotify_ids == {"s1", "t1"}

    def test_merge_same_id_rejected(self, merge_env):
        result = merge_ops.merge_series("source", "source")
        assert not result.ok
        assert "different" in result.error

    def test_merge_missing_source_curation(self, merge_env):
        (merge_env["curation_dir"] / "source.json").unlink()
        result = merge_ops.merge_series("source", "target")
        assert not result.ok
        assert "not found" in result.error

    def test_merge_creates_target_curation_if_missing(self, merge_env):
        (merge_env["curation_dir"] / "target.json").unlink()
        result = merge_ops.merge_series("source", "target", target_title="Target")
        assert result.ok
        assert result.added == 2


class TestSplitOps:
    @pytest.fixture
    def split_env(self, merge_env):
        """A series with a split proposal in review."""
        curation = {
            "id": "parent",
            "title": "Parent Series",
            "episode_pattern": r"Folge\s+(\d+)",
            "provider_artist_ids": {"spotify": ["p1"]},
            "content_type": "hoerspiel",
            "albums": [
                {"album_id": "a1", "title": "Ep 1"},
                {"album_id": "a2", "title": "Ep 2"},
                {"album_id": "a3", "title": "Spinoff 1"},
            ],
            "review": {
                "splits": [
                    {
                        "new_series_id": "spinoff",
                        "new_series_title": "Spinoff Series",
                        "album_ids": ["a3"],
                    },
                ],
            },
        }
        (merge_env["curation_dir"] / "parent.json").write_text(json.dumps(curation))
        return merge_env

    def test_reject_split(self, split_env):
        result = merge_ops.reject_split("parent", 0)
        assert result.ok
        assert result.action == "rejected"

        data = json.loads((split_env["curation_dir"] / "parent.json").read_text())
        assert len(data["review"]["splits"]) == 0

    def test_accept_split_creates_new_curation(self, split_env):
        result = merge_ops.accept_split("parent", 0)
        assert result.ok
        assert result.action == "accepted"
        assert result.new_id == "spinoff"

        new_path = split_env["curation_dir"] / "spinoff.json"
        assert new_path.exists()
        new_data = json.loads(new_path.read_text())
        assert len(new_data["albums"]) == 1
        assert new_data["albums"][0]["album_id"] == "a3"

    def test_accept_split_removes_albums_from_parent(self, split_env):
        merge_ops.accept_split("parent", 0)
        parent = json.loads((split_env["curation_dir"] / "parent.json").read_text())
        album_ids = [a["album_id"] for a in parent["albums"]]
        assert "a3" not in album_ids
        assert "a1" in album_ids

    def test_accept_split_adds_to_series_yaml(self, split_env):
        merge_ops.accept_split("parent", 0)
        data = yaml.load(split_env["series_yaml"])
        ids = [e["id"] for e in data["series"]]
        assert "spinoff" in ids

    def test_split_nonexistent_curation(self, split_env):
        result = merge_ops.accept_split("nonexistent", 0)
        assert not result.ok
        assert "not found" in result.error

    def test_split_invalid_index(self, split_env):
        result = merge_ops.reject_split("parent", 99)
        assert not result.ok
        assert "not found" in result.error
