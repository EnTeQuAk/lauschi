"""Tests for catalog.io module."""

from __future__ import annotations

import json

from lauschi_catalog.catalog import io as io_mod


def test_safe_write_text(tmp_path):
    path = tmp_path / "test.txt"
    io_mod.safe_write_text(path, "hello world")
    assert path.read_text() == "hello world"
    assert not path.with_suffix(".txt.tmp").exists()


def test_safe_write_json(tmp_path):
    path = tmp_path / "test.json"
    data = {"key": "value", "num": 42}
    io_mod.safe_write_json(path, data)
    loaded = json.loads(path.read_text())
    assert loaded == data


def test_safe_write_yaml(tmp_path):
    from ruamel.yaml import YAML

    path = tmp_path / "test.yaml"
    data = {"series": [{"id": "test", "title": "Test"}]}
    io_mod.safe_write_yaml(path, data)
    yaml = YAML()
    loaded = yaml.load(path)
    assert loaded["series"][0]["id"] == "test"


def test_safe_write_text_is_atomic(tmp_path):
    """Verify that safe_write_text overwrites existing content cleanly."""
    path = tmp_path / "test.txt"
    path.write_text("original")
    io_mod.safe_write_text(path, "replaced")
    assert path.read_text() == "replaced"


def test_load_raw_reads_yaml(tmp_path, monkeypatch):
    from ruamel.yaml import YAML

    path = tmp_path / "series.yaml"
    yaml = YAML()
    yaml.dump({"series": [{"id": "foo", "title": "Foo"}]}, path)
    data = io_mod.load_raw(path)
    assert data["series"][0]["id"] == "foo"


def test_save_raw_with_lock(tmp_path, monkeypatch):
    """save_raw uses FileLock and atomic write."""
    from lauschi_catalog.catalog import paths as paths_mod
    from ruamel.yaml import YAML

    yaml_path = tmp_path / "series.yaml"
    yaml = YAML()
    yaml.dump({"series": []}, yaml_path)

    monkeypatch.setattr(paths_mod, "series_yaml_path", lambda: yaml_path)
    monkeypatch.setattr(paths_mod, "series_lock_path", lambda: tmp_path / ".lock")

    io_mod.save_raw({"series": [{"id": "bar", "title": "Bar"}]})
    loaded = yaml.load(yaml_path)
    assert loaded["series"][0]["id"] == "bar"
