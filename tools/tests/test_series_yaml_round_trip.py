"""series.yaml round-trip identity test.

Guards against ruamel.yaml configuration drift: every code path that
reads or writes the canonical catalog must use the same YAML instance
settings (preserve_quotes, width 200), otherwise comments and quoting
reflow and the diff becomes unreadable.
"""

from __future__ import annotations

from pathlib import Path

from lauschi_catalog.catalog import loader, paths


def test_series_yaml_round_trip(tmp_path: Path) -> None:
    """load -> save must reproduce series.yaml byte-for-byte."""
    original_path = paths.series_yaml_path()
    original_bytes = original_path.read_bytes()

    data = loader.load_raw(original_path)

    roundtrip_path = tmp_path / "series.yaml"
    loader.save_raw(data, roundtrip_path)

    assert roundtrip_path.read_bytes() == original_bytes
