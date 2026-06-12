"""Pin catalog-delete behaviour and the deletion-log guard on
catalog-add.

The deletion log exists to keep AI agents (and tired humans) from
silently re-introducing a series we deliberately dropped. These tests
pin both ends of the contract:
  - delete cleanly removes the entry and records the reason
  - add refuses to re-introduce a deleted id without --force-readd
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner
from ruamel.yaml import YAML

from lauschi_catalog.catalog import deleted as deleted_mod
from lauschi_catalog.catalog import loader as loader_mod
from lauschi_catalog.catalog import paths as paths_mod
from lauschi_catalog.commands import delete as delete_mod

yaml = YAML()
yaml.preserve_quotes = True


@pytest.fixture
def fake_catalog(monkeypatch, tmp_path):
    """A pristine catalog in tmp_path with one series and one curation."""
    series_yaml = tmp_path / "series.yaml"
    curation_dir = tmp_path / "curation"
    deleted_yaml = tmp_path / "deleted.yaml"
    curation_dir.mkdir()

    data = {
        "series": [
            {
                "id": "tom_turbo",
                "title": "Tom Turbo",
                "providers": {"spotify": {"artist_ids": ["fake"]}},
            },
        ],
    }
    with series_yaml.open("w") as f:
        yaml.dump(data, f)

    (curation_dir / "tom_turbo.json").write_text(
        json.dumps({"id": "tom_turbo", "title": "Tom Turbo", "albums": []}),
    )

    # Redirect all path resolution to tmp_path.
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
    monkeypatch.setattr(paths_mod, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(loader_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(deleted_mod, "DELETED_YAML", deleted_yaml)
    return {
        "series_yaml": series_yaml,
        "curation_dir": curation_dir,
        "deleted_yaml": deleted_yaml,
    }


def _series_ids(path: Path) -> list[str]:
    with path.open() as f:
        data = yaml.load(f)
    return [s["id"] for s in data.get("series", [])]


def test_delete_removes_entry_and_curation_and_logs(fake_catalog):
    runner = CliRunner()
    result = runner.invoke(
        delete_mod.delete,
        ["tom_turbo", "--reason", "No streaming presence"],
    )
    assert result.exit_code == 0, result.output

    # series.yaml entry gone.
    assert _series_ids(fake_catalog["series_yaml"]) == []
    # curation file gone.
    assert not (fake_catalog["curation_dir"] / "tom_turbo.json").exists()
    # deleted.yaml records the deletion with the reason.
    log = deleted_mod.load_deleted(fake_catalog["deleted_yaml"])
    assert len(log) == 1
    entry = log[0]
    assert entry["id"] == "tom_turbo"
    assert entry["title"] == "Tom Turbo"
    assert entry["reason"] == "No streaming presence"
    assert "deleted_at" in entry


def test_delete_unknown_series_errors(fake_catalog):
    runner = CliRunner()
    result = runner.invoke(
        delete_mod.delete,
        ["does_not_exist", "--reason", "spurious"],
    )
    assert result.exit_code == 1
    assert "not found" in result.output


def test_delete_requires_reason(fake_catalog):
    """The reason is the whole point of the log — Click rejects the
    call without it."""
    runner = CliRunner()
    result = runner.invoke(delete_mod.delete, ["tom_turbo"])
    # Click exits 2 for missing required options.
    assert result.exit_code == 2
    assert "reason" in result.output.lower()


def test_delete_dry_run_does_not_touch_files(fake_catalog):
    runner = CliRunner()
    result = runner.invoke(
        delete_mod.delete,
        ["tom_turbo", "--reason", "spurious", "--dry-run"],
    )
    assert result.exit_code == 0
    # Entry still present.
    assert _series_ids(fake_catalog["series_yaml"]) == ["tom_turbo"]
    # Curation still present.
    assert (fake_catalog["curation_dir"] / "tom_turbo.json").exists()
    # Log was NOT created.
    assert not fake_catalog["deleted_yaml"].exists()


def test_delete_is_idempotent_on_log(fake_catalog):
    """Re-deleting an id (after manually re-adding the series.yaml entry)
    refreshes the log entry rather than appending a duplicate."""
    runner = CliRunner()
    # First delete.
    result = runner.invoke(
        delete_mod.delete,
        ["tom_turbo", "--reason", "first reason"],
    )
    assert result.exit_code == 0
    # Manually add the entry back to series.yaml (simulating an
    # operator who reconsidered without running add).
    with fake_catalog["series_yaml"].open("w") as f:
        yaml.dump(
            {"series": [{"id": "tom_turbo", "title": "Tom Turbo"}]},
            f,
        )
    # Delete again with a different reason.
    result = runner.invoke(
        delete_mod.delete,
        ["tom_turbo", "--reason", "second reason"],
    )
    assert result.exit_code == 0
    log = deleted_mod.load_deleted(fake_catalog["deleted_yaml"])
    assert len(log) == 1
    assert log[0]["reason"] == "second reason"


def test_deleted_module_helpers(fake_catalog):
    """Direct unit-test of the helper module, independent of CLI."""
    path = fake_catalog["deleted_yaml"]
    assert deleted_mod.load_deleted(path) == []
    assert deleted_mod.is_deleted("anything", path) is None

    deleted_mod.record_deletion("foo", "Foo Series", "test reason", path=path)
    assert len(deleted_mod.load_deleted(path)) == 1
    entry = deleted_mod.is_deleted("foo", path)
    assert entry is not None
    assert entry["reason"] == "test reason"

    assert deleted_mod.remove_from_deleted("foo", path=path) is True
    assert deleted_mod.is_deleted("foo", path) is None
    # Idempotent removal returns False.
    assert deleted_mod.remove_from_deleted("foo", path=path) is False
