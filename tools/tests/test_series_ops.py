"""Tests for catalog.series_ops module."""

import pytest

from lauschi_catalog.catalog import series_ops
from lauschi_catalog.catalog.apply_ops import apply_curations
from lauschi_catalog.catalog.io import load_raw, write_catalog
from tests.conftest import ScratchCatalog


@pytest.fixture
def catalog_env(scratch_catalog: ScratchCatalog) -> ScratchCatalog:
    scratch_catalog.write_series(
        {"id": "bibi_blocksberg", "title": "Bibi Blocksberg", "providers": {}},
        {"id": "tkkg", "title": "TKKG", "providers": {}},
    )
    return scratch_catalog


class TestEditSeries:
    def test_edit_title(self, catalog_env):
        changes = series_ops.SeriesChanges(title="Bibi Blocksberg NEU")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok
        assert result.series_id == "bibi_blocksberg"

        data = load_raw(catalog_env.series_json)
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry["title"] == "Bibi Blocksberg NEU"

    def test_edit_id_renames(self, catalog_env):
        cur = catalog_env.write_curation({"id": "bibi_blocksberg", "albums": []})

        changes = series_ops.SeriesChanges(id="bibi")
        result = series_ops.edit_series("bibi_blocksberg", changes)
        assert result.ok
        assert result.series_id == "bibi"
        assert not cur.exists()
        assert (catalog_env.curation_dir / "bibi.json").exists()

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

        data = load_raw(catalog_env.series_json)
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

        data = load_raw(catalog_env.series_json)
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry["content_type"] == "music"

    @pytest.mark.parametrize(
        ("changes", "key", "expected"),
        [
            pytest.param(
                series_ops.SeriesChanges(episode_pattern=r"^Folge (\d+):"),
                "episode_pattern",
                r"^Folge (\d+):",
                id="another pattern",
            ),
            pytest.param(
                series_ops.SeriesChanges(episode_pattern=[]),
                "episode_pattern",
                None,
                id="no pattern",
            ),
            pytest.param(
                series_ops.SeriesChanges(content_type="music"),
                "content_type",
                "music",
                id="another content type",
            ),
        ],
    )
    def test_an_edit_survives_the_next_apply(self, catalog_env, changes, key, expected):
        """apply writes a curation's pattern and content type into
        series.json. An edit that reached series.json alone was written
        over with the next apply, by the curation's older value."""
        data = load_raw(catalog_env.series_json)
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        entry["episode_pattern"] = r"^(\d+)/"
        entry["providers"] = {"spotify": {"artist_ids": ["a"]}}
        write_catalog(catalog_env.series_json, data)
        catalog_env.write_curation(
            {
                "id": "bibi_blocksberg",
                "title": "Bibi Blocksberg",
                "episode_pattern": r"^(\d+)/",
                "content_type": "hoerspiel",
                "albums": [
                    {
                        "album_id": "a1",
                        "provider": "spotify",
                        "include": True,
                        "title": "1/Hexen gibt es doch",
                        "episode_num": 1,
                    }
                ],
            }
        )

        assert series_ops.edit_series("bibi_blocksberg", changes).ok
        applied = apply_curations("bibi_blocksberg", allow_unreviewed=True)

        assert applied.applied == 1
        data = load_raw(catalog_env.series_json)
        entry = next(e for e in data["series"] if e["id"] == "bibi_blocksberg")
        assert entry.get(key) == expected


class TestDeleteSeries:
    def test_delete_removes_and_logs(self, catalog_env):
        cur = catalog_env.write_curation({"id": "bibi_blocksberg"})

        result = series_ops.delete_series("bibi_blocksberg", reason="test")
        assert result.ok
        assert result.title == "Bibi Blocksberg"
        assert result.curation_removed

        data = load_raw(catalog_env.series_json)
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

        data = load_raw(catalog_env.series_json)
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


class TestRemoveSeriesEntry:
    def test_remove_existing(self, catalog_env):
        assert series_ops.remove_series_entry("tkkg")
        data = load_raw(catalog_env.series_json)
        ids = [e["id"] for e in data["series"]]
        assert "tkkg" not in ids

    def test_remove_nonexistent_returns_false(self, catalog_env):
        assert not series_ops.remove_series_entry("nonexistent")
