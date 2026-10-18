"""Catalog files round-trip identity test.

Guards against layout drift: every code path that reads or writes a
catalog file goes through the same writer, otherwise albums spread over
several lines or keys reorder and the diff becomes unreadable. It also
pins that the committed files are in that layout.
"""

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from lauschi_catalog.catalog import io, paths


@pytest.mark.parametrize(
    "committed",
    [
        pytest.param(paths.catalog_path, id="series.json"),
        pytest.param(paths.deleted_log_path, id="deleted.json"),
    ],
)
def test_catalog_round_trip(committed: Callable[[], Path], tmp_path: Path) -> None:
    """load -> write must reproduce the committed file byte-for-byte."""
    original_bytes = committed().read_bytes()

    roundtrip_path = tmp_path / "round_trip.json"
    io.write_catalog(roundtrip_path, json.loads(original_bytes))

    assert roundtrip_path.read_bytes() == original_bytes
