"""Tests for catalog.series_ops module."""

from __future__ import annotations

import json

import pytest
from ruamel.yaml import YAML

from lauschi_catalog.catalog import paths as paths_mod
from lauschi_catalog.catalog import loader as loader_mod
from lauschi_catalog.catalog import series_ops
from lauschi_catalog.catalog import deleted as deleted_mod

yaml = YAML()
yaml.preserve_quotes = True


@pytest.fixture
def catalog_env(monkeypatch, tmp_path):
    """Set up a temporary catalog with one series."""
    series_yaml = tmp_path / "series.yaml"
    curation_dir = tmp_path / "curation"
    deleted_yaml = tmp_path / "deleted.yaml"
    curation_dir.mkdir()

    yaml.dump(
        {
            "series": [
                {"id": "bibi_blocksberg", "title": "Bibi Blocksberg", "providers": {}},
                {"id": "tkkg", "title": "TKKG", "providers": {}},
            ],
        },
        series_yaml,
    )

    monkeypatch.setattr(paths_mod, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(paths_mod, "series_yaml_path", lambda: series_yaml)
    monkeypatch.setattr(paths_mod, "curation_dir", lambda: curation_dir)
    monkeypatch.setattr(
        paths_mod, "curation_path", lambda sid: curation_dir / f"{sid}.json"
    )
    monkeypatch.setattr(paths_mod, "series_lock_path", lambda: tmp_path / ".lock")
    monkeypatch.setattr(paths_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(paths_mod, "CURATION_DIR", curation_dir)
    monkeypatch.setattr(paths_mod, "SERIES_LOCK", tmp_path / ".lock")
    monkeypatch.setattr(loader_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(deleted_mod, "DELETED_YAML", deleted_yaml)

    return {
        "series_yaml": series_yaml,
        "curation_dir": curation_dir,
        "deleted_yaml": deleted_yaml,
    }


class TestEditSeries:
    def test_edit_title(self, catalog_env):
        changes = series_ops.SeriesChanges(title="Bibi Blocksberg NEU")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok
        assert result.series_id == "bibi_blocksberg"

        data = yaml.load(catalog_env["series_yaml"])
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry["title"] == "Bibi Blocksberg NEU"

    def test_edit_id_renames(self, catalog_env):
        # Create a curation file
        cur = catalog_env["curation_dir"] / "bibi_blocksberg.json"
        cur.write_text(json.dumps({"id": "bibi_blocksberg", "albums": []}))

        changes = series_ops.SeriesChanges(id="bibi")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok
        assert result.series_id == "bibi"
        assert not cur.exists()
        assert (catalog_env["curation_dir"] / "bibi.json").exists()

    def test_edit_invalid_id_rejected(self, catalog_env):
        changes = series_ops.SeriesChanges(id="INVALID!")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert not result.ok
        assert "snake_case" in result.error

    def test_edit_duplicate_id_rejected(self, catalog_env):
        changes = series_ops.SeriesChanges(id="tkkg")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert not result.ok
        assert "already exists" in result.error

    def test_edit_nonexistent_series(self, catalog_env):
        changes = series_ops.SeriesChanges(title="X")
        result = series_ops.edit_series("nonexistent", changes)
        assert not result.ok
        assert "not found" in result.error

    def test_edit_episode_pattern(self, catalog_env):
        changes = series_ops.SeriesChanges(episode_pattern=r"Folge\s+(\d+)")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok

        data = yaml.load(catalog_env["series_yaml"])
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry["episode_pattern"] == r"Folge\s+(\d+)"

    def test_edit_invalid_pattern_rejected(self, catalog_env):
        changes = series_ops.SeriesChanges(episode_pattern="no_capture_group")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert not result.ok
        assert "capture group" in result.error

    def test_edit_content_type(self, catalog_env):
        changes = series_ops.SeriesChanges(content_type="music")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok

        data = yaml.load(catalog_env["series_yaml"])
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry["content_type"] == "music"


class TestDeleteSeries:
    def test_delete_removes_and_logs(self, catalog_env):
        cur = catalog_env["curation_dir"] / "bibi_blocksberg.json"
        cur.write_text(json.dumps({"id": "bibi_blocksberg"}))

        result = series_ops.delete_series("bibi_blocksberg", reason="test")
        assert result.ok
        assert result.title == "Bibi Blocksberg"
        assert result.curation_removed

        data = yaml.load(catalog_env["series_yaml"])
        ids = [e["id"] for e in data["series"]]
        assert "bibi_blocksberg" not in ids
        assert not cur.exists()

    def test_delete_nonexistent(self, catalog_env):
        result = series_ops.delete_series("nonexistent", reason="test")
        assert not result.ok
        assert "not found" in result.error


class TestAddSeriesEntry:
    def test_add_new_entry(self, catalog_env):
        entry = {"id": "benjamin_bluemchen", "title": "Benjamin Blümchen"}
        result = series_ops.add_series_entry(entry)
        assert result.ok
        assert result.series_id == "benjamin_bluemchen"

        data = yaml.load(catalog_env["series_yaml"])
        ids = [e["id"] for e in data["series"]]
        assert "benjamin_bluemchen" in ids

    def test_add_duplicate_rejected(self, catalog_env):
        entry = {"id": "tkkg", "title": "TKKG"}
        result = series_ops.add_series_entry(entry)
        assert not result.ok
        assert "already exists" in result.error

    def test_add_missing_id_rejected(self, catalog_env):
        result = series_ops.add_series_entry({"title": "No ID"})
        assert not result.ok
        assert "id is required" in result.error


class TestRemoveSeriesFromYaml:
    def test_remove_existing(self, catalog_env):
        assert series_ops.remove_series_from_yaml("tkkg")
        data = yaml.load(catalog_env["series_yaml"])
        ids = [e["id"] for e in data["series"]]
        assert "tkkg" not in ids

    def test_remove_nonexistent_returns_false(self, catalog_env):
        assert not series_ops.remove_series_from_yaml("nonexistent")
