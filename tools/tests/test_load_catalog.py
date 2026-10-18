"""load_catalog reads series.json fresh on every call.

Each caller gets entries of its own, so one mutation cannot leak into
anyone else's view, and a write shows on the next load.
"""

from pathlib import Path

import pytest

from lauschi_catalog.catalog import loader
from lauschi_catalog.catalog.io import write_catalog
from lauschi_catalog.catalog.series_ops import add_series_entry
from tests.conftest import ScratchCatalog


def _write(path: Path, ids: list[str]) -> None:
    write_catalog(
        path,
        {
            "series": [
                {"id": i, "title": i.replace("_", " ").title(), "providers": {}}
                for i in ids
            ]
        },
    )


@pytest.fixture
def catalog_file(scratch_catalog: ScratchCatalog) -> Path:
    return scratch_catalog.series_json


def test_mutating_a_returned_entry_does_not_leak_into_the_next_load(
    catalog_file: Path,
) -> None:
    _write(catalog_file, ["kira"])
    first = loader.load_catalog()
    first[0].title = "MUTATED"
    assert loader.load_catalog()[0].title == "Kira"


def test_a_write_through_series_ops_shows_on_the_next_load(
    catalog_file: Path,
) -> None:
    _write(catalog_file, ["a"])
    loader.load_catalog()
    assert add_series_entry({"id": "c", "title": "C"}).ok
    assert [e.id for e in loader.load_catalog()] == ["a", "c"]


def test_a_missing_file_is_an_empty_catalog(tmp_path: Path) -> None:
    assert loader.load_catalog(tmp_path / "nope.json") == []
