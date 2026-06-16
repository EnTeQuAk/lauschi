"""Tests for the `splits` CLI command group."""

from __future__ import annotations

import json

import pytest
from click.testing import CliRunner
from ruamel.yaml import YAML

from lauschi_catalog.catalog import paths as paths_mod
from lauschi_catalog.catalog import loader as loader_mod
from lauschi_catalog.commands import apply_splits as splits_mod

yaml = YAML()
yaml.preserve_quotes = True


@pytest.fixture
def split_env(monkeypatch, tmp_path):
    """A series with two split proposals."""
    series_yaml = tmp_path / "series.yaml"
    curation_dir = tmp_path / "curation"
    curation_dir.mkdir()

    yaml.dump(
        {
            "series": [
                {"id": "parent", "title": "Parent Series", "providers": {}},
            ],
        },
        series_yaml,
    )

    curation = {
        "id": "parent",
        "title": "Parent Series",
        "episode_pattern": r"Folge\s+(\d+)",
        "provider_artist_ids": {"spotify": ["p1"]},
        "content_type": "hoerspiel",
        "age_note": "ab 6 Jahren",
        "albums": [
            {"album_id": "a1", "provider": "spotify", "title": "Folge 1"},
            {"album_id": "a2", "provider": "spotify", "title": "Folge 2"},
            {"album_id": "a3", "provider": "spotify", "title": "Kids Folge 1"},
            {"album_id": "a4", "provider": "spotify", "title": "Film 1"},
            {"album_id": "a5", "provider": "spotify", "title": "Film 2"},
        ],
        "series_facts": {
            "sub_series": [
                {
                    "label": "kids",
                    "album_ids": ["a3"],
                    "reason": "Age-bracket product line",
                },
                {
                    "label": "kinofilm",
                    "album_ids": ["a4", "a5"],
                    "reason": "Film Hörspiele",
                },
            ],
        },
    }
    (curation_dir / "parent.json").write_text(json.dumps(curation))

    monkeypatch.setattr(paths_mod, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(paths_mod, "series_yaml_path", lambda: series_yaml)
    monkeypatch.setattr(paths_mod, "curation_dir", lambda: curation_dir)
    monkeypatch.setattr(
        paths_mod, "curation_path", lambda sid: curation_dir / f"{sid}.json"
    )
    monkeypatch.setattr(paths_mod, "series_lock_path", lambda: tmp_path / ".lock")
    monkeypatch.setattr(paths_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(paths_mod, "CURATION_DIR", curation_dir)
    monkeypatch.setattr(loader_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(splits_mod, "CURATION_DIR", curation_dir)

    return {
        "series_yaml": series_yaml,
        "curation_dir": curation_dir,
    }


class TestList:
    def test_lists_pending_splits(self, split_env):
        runner = CliRunner()
        result = runner.invoke(splits_mod.apply_splits, ["list"])
        assert result.exit_code == 0, result.output
        assert "Parent Series" in result.output
        assert "kids" in result.output
        assert "kinofilm" in result.output
        assert "1 album" in result.output
        assert "2 albums" in result.output

    def test_list_with_albums_flag(self, split_env):
        runner = CliRunner()
        result = runner.invoke(splits_mod.apply_splits, ["list", "--albums"])
        assert result.exit_code == 0, result.output
        assert "Kids Folge 1" in result.output
        assert "Film 1" in result.output

    def test_list_single_series(self, split_env):
        runner = CliRunner()
        result = runner.invoke(splits_mod.apply_splits, ["list", "parent"])
        assert result.exit_code == 0, result.output
        assert "kids" in result.output

    def test_list_empty(self, split_env):
        (split_env["curation_dir"] / "parent.json").write_text(
            json.dumps({"id": "parent", "series_facts": {}})
        )
        runner = CliRunner()
        result = runner.invoke(splits_mod.apply_splits, ["list"])
        assert result.exit_code == 0
        assert "No pending" in result.output


class TestShow:
    def test_shows_split_details(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["show", "parent", "kinofilm"]
        )
        assert result.exit_code == 0, result.output
        assert "Film 1" in result.output
        assert "Film 2" in result.output
        assert "parent_kinofilm" in result.output

    def test_show_nonexistent_label(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["show", "parent", "nonexistent"]
        )
        assert result.exit_code == 1
        assert "nonexistent" in result.output
        assert "kids" in result.output  # shows available labels


class TestAccept:
    def test_accept_creates_new_series(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["accept", "parent", "kids"]
        )
        assert result.exit_code == 0, result.output
        assert "parent_kids" in result.output

        new_path = split_env["curation_dir"] / "parent_kids.json"
        assert new_path.exists()
        new_data = json.loads(new_path.read_text())
        assert len(new_data["albums"]) == 1
        assert new_data["albums"][0]["album_id"] == "a3"

    def test_accept_removes_albums_from_parent(self, split_env):
        runner = CliRunner()
        runner.invoke(splits_mod.apply_splits, ["accept", "parent", "kids"])

        parent = json.loads(
            (split_env["curation_dir"] / "parent.json").read_text()
        )
        album_ids = [a["album_id"] for a in parent["albums"]]
        assert "a3" not in album_ids
        assert "a1" in album_ids

    def test_accept_with_custom_id_and_title(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits,
            [
                "accept", "parent", "kids",
                "--id", "parent_junior",
                "--title", "Parent Series Junior",
            ],
        )
        assert result.exit_code == 0, result.output
        assert "parent_junior" in result.output

        new_path = split_env["curation_dir"] / "parent_junior.json"
        assert new_path.exists()
        new_data = json.loads(new_path.read_text())
        assert new_data["title"] == "Parent Series Junior"

    def test_accept_nonexistent_label(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["accept", "parent", "nonexistent"]
        )
        assert result.exit_code == 1

    def test_sequential_accepts_work(self, split_env):
        """Accepting one split doesn't break accepting the next."""
        runner = CliRunner()
        r1 = runner.invoke(
            splits_mod.apply_splits, ["accept", "parent", "kids"]
        )
        assert r1.exit_code == 0, r1.output

        r2 = runner.invoke(
            splits_mod.apply_splits, ["accept", "parent", "kinofilm"]
        )
        assert r2.exit_code == 0, r2.output

        # Both new series exist
        assert (split_env["curation_dir"] / "parent_kids.json").exists()
        assert (split_env["curation_dir"] / "parent_kinofilm.json").exists()

        # Parent has only the main episodes left
        parent = json.loads(
            (split_env["curation_dir"] / "parent.json").read_text()
        )
        album_ids = {a["album_id"] for a in parent["albums"]}
        assert album_ids == {"a1", "a2"}


class TestReject:
    def test_reject_removes_proposal(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["reject", "parent", "kids"]
        )
        assert result.exit_code == 0, result.output

        data = json.loads(
            (split_env["curation_dir"] / "parent.json").read_text()
        )
        labels = [
            s["label"] for s in data["series_facts"]["sub_series"]
        ]
        assert "kids" not in labels
        assert "kinofilm" in labels

    def test_reject_keeps_albums_in_parent(self, split_env):
        runner = CliRunner()
        runner.invoke(splits_mod.apply_splits, ["reject", "parent", "kids"])

        parent = json.loads(
            (split_env["curation_dir"] / "parent.json").read_text()
        )
        album_ids = [a["album_id"] for a in parent["albums"]]
        assert "a3" in album_ids

    def test_reject_nonexistent_label(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["reject", "parent", "nonexistent"]
        )
        assert result.exit_code == 1


class TestAcceptAll:
    def test_accept_all_creates_all(self, split_env):
        runner = CliRunner()
        result = runner.invoke(
            splits_mod.apply_splits, ["accept-all", "parent"]
        )
        assert result.exit_code == 0, result.output
        assert "parent_kids" in result.output
        assert "parent_kinofilm" in result.output
        assert (split_env["curation_dir"] / "parent_kids.json").exists()
        assert (split_env["curation_dir"] / "parent_kinofilm.json").exists()

    def test_accept_all_empty(self, split_env):
        (split_env["curation_dir"] / "parent.json").write_text(
            json.dumps({"id": "parent", "series_facts": {}})
        )
        runner = CliRunner()
        result = runner.invoke(splits_mod.apply_splits, ["accept-all"])
        assert result.exit_code == 0
        assert "No pending" in result.output
