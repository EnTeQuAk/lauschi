"""The series.yaml parse is cached per process, keyed by file state.

load_catalog() was a full 1.6 MB ruamel round trip (3.5 s measured) per
series for several call paths during --all runs: ~10 min of parsing per
catalog sweep. The file rarely changes inside a process; the cache key
is (size, mtime_ns) so any write, even a same-size one, re-parses.
"""

import io
from pathlib import Path

import pytest
from ruamel.yaml import YAML

from lauschi_catalog.catalog import loader

yaml = YAML()
yaml.preserve_quotes = True


def _write_catalog(path: Path, ids: list[str]) -> None:
    data = {
        "series": [
            {"id": i, "title": i.replace("_", " ").title(), "providers": {}}
            for i in ids
        ]
    }
    buf = io.StringIO()
    yaml.dump(data, buf)
    path.write_text(buf.getvalue(), encoding="utf-8")


@pytest.fixture
def scratch(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    catalog = tmp_path / "assets" / "catalog"
    catalog.mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    loader.clear_catalog_cache()
    yield catalog / "series.yaml"
    loader.clear_catalog_cache()


@pytest.fixture
def parse_count(monkeypatch):
    """Count real yaml parses; the cache must collapse them."""
    calls = {"n": 0}
    real = loader._parse_catalog

    def counted(path):
        if not already_a_test_fixture(path):
            calls["n"] += 1
        return real(path)

    def already_a_test_fixture(_path) -> bool:
        return False  # every _parse_catalog call in this process counts

    monkeypatch.setattr(loader, "_parse_catalog", counted)
    return calls


class TestParseCache:
    def test_repeated_loads_parse_once(self, scratch, parse_count):
        _write_catalog(scratch, ["a", "b"])
        first = loader.load_catalog()
        second = loader.load_catalog()
        third = loader.load_catalog()
        assert [e.id for e in third] == ["a", "b"]
        # callers get per-call copies so cache poisoning is impossible
        assert first is not second is not third
        assert parse_count["n"] == 1

    def test_a_file_change_invalidates_the_cache(self, scratch, parse_count):
        _write_catalog(scratch, ["a"])
        assert [e.id for e in loader.load_catalog()] == ["a"]

        _write_catalog(scratch, ["a", "b", "c"])
        entries = loader.load_catalog()
        assert [e.id for e in entries] == ["a", "b", "c"]
        assert parse_count["n"] == 2

    def test_same_size_change_also_invalidates(self, scratch):
        """Same byte size with different content must not be confused
        for an unchanged file: the key carries mtime_ns."""
        _write_catalog(scratch, ["aa"])
        assert [e.id for e in loader.load_catalog()] == ["aa"]
        _write_catalog(scratch, ["bb"])
        assert [e.id for e in loader.load_catalog()] == ["bb"]

    def test_explicit_path_and_default_share_one_parse(
        self, tmp_path, monkeypatch, parse_count
    ):
        other = tmp_path / "series.yaml"
        _write_catalog(other, ["x"])
        first = loader.load_catalog(other)
        second = loader.load_catalog(other)
        assert first is not second
        assert [e.id for e in second] == ["x"]
        assert parse_count["n"] == 1

    def test_clear_cache_forces_a_reparse(self, scratch, parse_count):
        _write_catalog(scratch, ["a"])
        loader.load_catalog()
        loader.clear_catalog_cache()
        loader.load_catalog()
        assert parse_count["n"] == 2

    def test_mutating_a_returned_entry_does_not_poison_the_cache(self, scratch):
        """Callers each get their own deep copy: one mutation cannot leak
        into the next call's result (a read-only *contract* alone would
        make one bug a catalog-wide state leak)."""
        _write_catalog(scratch, ["kira"])
        first = loader.load_catalog()
        first[0].title = "MUTATED"
        clean = loader.load_catalog()
        assert clean[0].title == "Kira"

    def test_a_write_through_series_ops_picks_up_the_change(self, scratch, parse_count):
        from lauschi_catalog.catalog.series_ops import add_series_entry

        _write_catalog(scratch, ["a"])
        loader.load_catalog()  # prime the cache
        result = add_series_entry({"id": "c", "title": "C"})
        assert result.ok
        assert [e.id for e in loader.load_catalog()] == ["a", "c"]
        assert parse_count["n"] == 2

    def test_missing_file_is_an_empty_list_not_a_cache_hit(self, tmp_path):
        assert loader.load_catalog(tmp_path / "nope.yaml") == []
