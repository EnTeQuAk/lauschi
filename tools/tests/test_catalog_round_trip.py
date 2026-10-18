"""series.json round-trip identity test.

Guards against layout drift: every code path that reads or writes the
canonical catalog goes through the same reader and writer, otherwise
albums spread over several lines or keys reorder and the diff becomes
unreadable. It also pins that the committed file is in that layout.
"""

from pathlib import Path

from lauschi_catalog.catalog import io, paths


def test_catalog_round_trip(tmp_path: Path) -> None:
    """load -> write must reproduce series.json byte-for-byte."""
    original_path = paths.catalog_path()
    original_bytes = original_path.read_bytes()

    data = io.load_raw(original_path)

    roundtrip_path = tmp_path / "series.json"
    io.write_catalog(roundtrip_path, data)

    assert roundtrip_path.read_bytes() == original_bytes
