"""Catalog/curation divergence must be visible to the drift sweep.

A partial divergence (the catalog ships 8 albums, the curation
includes only 5) used to be invisible: an unresolved-series warning
fired only when the curation had zero records, so the remaining catalog
albums were silently never checked.
"""

import json

import pytest

from lauschi_catalog.catalog import drift_ops
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.paths import curation_path

pytestmark = pytest.mark.usefixtures("scratch_catalog")


def _entry(provider_albums: list[str]) -> CatalogEntry:
    return CatalogEntry(
        id="s1",
        title="S1",
        providers={
            "spotify": ProviderConfig(album_ids=provider_albums),
        },
    )


def _write_curation(series_id: str, included_ids: list[str]) -> None:
    albums = [
        {"album_id": aid, "provider": "spotify", "include": True, "title": f"T {aid}"}
        for aid in included_ids
    ]
    curation_path(series_id).write_text(json.dumps({"id": series_id, "albums": albums}))


def test_names_catalog_albums_missing_from_curation():
    _write_curation("s1", ["a1"])
    entry = _entry(["a1", "a2", "a3"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a2" in m for m in drift), drift
    assert any("a3" in m for m in drift), drift
    assert not any("a1" in m for m in drift), drift


def test_names_curation_albums_missing_from_the_catalog():
    _write_curation("s1", ["a1", "a9"])
    entry = _entry(["a1"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a9" in m for m in drift), drift
    assert not any("a1" in m for m in drift), drift


def test_no_findings_when_catalog_and_curation_agree():
    _write_curation("s1", ["a1", "a2"])
    entry = _entry(["a1", "a2"])

    assert drift_ops.configured_vs_curation(entry, "spotify") == []


def test_no_findings_when_the_catalog_configures_nothing():
    """A series that relies on artist-ID matching rather than configured
    album lists has nothing to compare against."""
    _write_curation("s1", ["a1"])

    assert drift_ops.configured_vs_curation(_entry([]), "spotify") == []


def test_zero_curation_records_with_catalog_albums_still_diverges():
    """The old unresolved-series signal, preserved as a divergence entry."""
    entry = _entry(["a1"])

    drift = drift_ops.configured_vs_curation(entry, "spotify")

    assert any("a1" in m for m in drift), drift
    assert any("no records" in m for m in drift), drift
