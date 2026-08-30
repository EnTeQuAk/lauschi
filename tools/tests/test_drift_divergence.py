"""Yaml/curation divergence must be visible to the drift sweep.

A partial divergence (series.yaml configures 8 albums, the curation
includes only 5) used to be invisible: an unresolved-series warning
fired only when the curation had zero records, so the remaining yaml
albums were silently never checked.
"""

from __future__ import annotations

import json

import pytest

from lauschi_catalog.catalog import drift_ops
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig


def _entry(provider_albums: list[str]) -> CatalogEntry:
    return CatalogEntry(
        id="s1",
        title="S1",
        providers={
            "spotify": ProviderConfig(album_ids=provider_albums),
        },
    )


@pytest.fixture
def scratch_root(tmp_path, monkeypatch):
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    curation_dir = tmp_path / "assets" / "catalog" / "curation"
    curation_dir.mkdir(parents=True)
    monkeypatch.setattr(drift_ops, "CURATION_DIR", curation_dir)
    return curation_dir


def _write_curation(series_id: str, included_ids: list[str]) -> None:
    albums = [
        {"album_id": aid, "provider": "spotify", "include": True, "title": f"T {aid}"}
        for aid in included_ids
    ]
    path = drift_ops.CURATION_DIR / f"{series_id}.json"
    path.write_text(json.dumps({"id": series_id, "albums": albums}))


def test_names_yaml_albums_missing_from_curation(scratch_root):
    _write_curation("s1", ["a1"])
    entry = _entry(["a1", "a2", "a3"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a2" in m for m in drift), drift
    assert any("a3" in m for m in drift), drift
    assert not any("a1" in m for m in drift), drift


def test_names_curation_albums_missing_from_yaml(scratch_root):
    _write_curation("s1", ["a1", "a9"])
    entry = _entry(["a1"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a9" in m for m in drift), drift
    assert not any("a1" in m for m in drift), drift


def test_no_findings_when_yaml_and_curation_agree(scratch_root):
    _write_curation("s1", ["a1", "a2"])
    entry = _entry(["a1", "a2"])

    assert drift_ops.configured_vs_curation(entry, "spotify") == []


def test_no_findings_when_yaml_configures_nothing(scratch_root):
    """A series that relies on artist-ID matching rather than configured
    album lists has nothing to compare against."""
    _write_curation("s1", ["a1"])

    assert drift_ops.configured_vs_curation(_entry([]), "spotify") == []


def test_zero_curation_records_with_yaml_albums_still_diverges(scratch_root):
    """The old unresolved-series signal, preserved as a divergence entry."""
    entry = _entry(["a1"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a1" in m for m in drift), drift
    assert any("no records" in m for m in drift), drift
