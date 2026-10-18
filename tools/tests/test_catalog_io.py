"""Tests for catalog.io module."""

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


def test_safe_write_text_is_atomic(tmp_path):
    """Verify that safe_write_text overwrites existing content cleanly."""
    path = tmp_path / "test.txt"
    path.write_text("original")
    io_mod.safe_write_text(path, "replaced")
    assert path.read_text() == "replaced"


def test_load_raw_reads_the_catalog(tmp_path):
    path = tmp_path / "series.json"
    io_mod.write_catalog(path, {"series": [{"id": "foo", "title": "Foo"}]})
    data = io_mod.load_raw(path)
    assert data["series"][0]["id"] == "foo"


def test_save_raw_with_lock(tmp_path, monkeypatch):
    """save_raw uses FileLock and atomic write."""
    from lauschi_catalog.catalog import paths as paths_mod

    catalog_file = tmp_path / "series.json"
    io_mod.write_catalog(catalog_file, {"series": []})

    monkeypatch.setattr(paths_mod, "catalog_path", lambda: catalog_file)
    monkeypatch.setattr(paths_mod, "series_lock_path", lambda: tmp_path / ".lock")

    io_mod.save_raw({"series": [{"id": "bar", "title": "Bar"}]})
    loaded = json.loads(catalog_file.read_text())
    assert loaded["series"][0]["id"] == "bar"
