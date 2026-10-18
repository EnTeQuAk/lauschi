"""Drift reads the barcode: the surest sign that a store id still holds
the release we recorded.

A barcode names one release on both stores. An id whose live record
carries another barcode holds another release, whatever its title says.
A gone id is looked up by its barcode, which names the id the store
moved the release to. A record without a barcode gets the live one.
"""

import json
from pathlib import Path

import pytest

from lauschi_catalog.catalog.drift_ops import (
    DriftSeverity,
    classify_album_drift,
    detect_drift,
    record_barcodes,
)
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.paths import curation_path
from lauschi_catalog.providers.base import Album, AlbumBatch, Artist, CatalogProvider

FOLGE = r"^Folge (\d+):"


def _classify(stored_barcode: str, live_barcode: str):
    return classify_album_drift(
        album_id="a1",
        provider="apple_music",
        stored_title="Folge 59: Die Zauberschule",
        stored_episode=59,
        stored_release="2010-01-01",
        live_title="Folge 59: Die Zauberschule",
        live_release="2010-01-01",
        pattern=FOLGE,
        stored_barcode=stored_barcode,
        live_barcode=live_barcode,
    )


def test_another_barcode_on_the_same_id_is_critical() -> None:
    finding = _classify("4001504265595", "4001504265618")
    assert finding is not None
    assert finding.severity is DriftSeverity.critical
    assert "4001504265618" in finding.detail


@pytest.mark.parametrize(
    ("stored", "live"),
    [("4001504265595", "4001504265595"), ("", "4001504265595"), ("4001", "")],
)
def test_an_equal_or_unknown_barcode_is_no_drift(stored: str, live: str) -> None:
    assert _classify(stored, live) is None


class _Store(CatalogProvider):
    """A store that holds ``albums`` by id and files them by barcode."""

    def __init__(self, albums: list[Album]) -> None:
        self.albums = albums

    @property
    def name(self) -> str:
        return "apple_music"

    def albums_by_ids(self, album_ids: list[str]) -> AlbumBatch:
        return AlbumBatch([a for a in self.albums if a.id in album_ids])

    def albums_by_barcode(self, barcode: str) -> list[Album]:
        return [a for a in self.albums if a.barcode == barcode]

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        raise NotImplementedError

    def artist_exists(self, artist_id: str) -> bool:
        raise NotImplementedError

    def artist_details(self, artist_id: str) -> Artist | None:
        raise NotImplementedError

    def artist_albums(self, artist_id: str) -> list[Album]:
        raise NotImplementedError

    def album_details(self, album_id: str) -> Album | None:
        raise NotImplementedError

    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        raise NotImplementedError


@pytest.fixture
def lilli(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> CatalogEntry:
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    records = [
        ("old", "Folge 1: Die Zauberschule", "4001504265595"),
        ("a2", "Folge 2: Der Drache", ""),
    ]
    path = curation_path("hexe_lilli")
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "id": "hexe_lilli",
                "albums": [
                    {
                        "album_id": album_id,
                        "provider": "apple_music",
                        "include": True,
                        "title": title,
                        "episode_num": n,
                        "release_date": "2010-01-01",
                        "barcode": barcode,
                    }
                    for n, (album_id, title, barcode) in enumerate(records, 1)
                ],
            }
        )
    )
    return CatalogEntry(
        id="hexe_lilli",
        title="Hexe Lilli",
        episode_pattern=FOLGE,
        providers={"apple_music": ProviderConfig(album_ids=["old", "a2"])},
    )


STORE = _Store(
    [
        Album(
            "new", "Folge 1: Die Zauberschule", "apple_music", barcode="4001504265595"
        ),
        Album("a2", "Folge 2: Der Drache", "apple_music", barcode="4001504265618"),
    ]
)


def test_a_gone_id_names_the_id_its_barcode_moved_to(lilli: CatalogEntry) -> None:
    result = detect_drift([lilli], [STORE])

    (gone,) = result.by_severity(DriftSeverity.gone)
    assert gone.album_id == "old"
    assert gone.moved_to is not None and gone.moved_to.id == "new"
    assert "album new" in gone.detail


def test_a_record_without_a_barcode_gets_the_live_one(lilli: CatalogEntry) -> None:
    result = detect_drift([lilli], [STORE])
    assert result.barcodes == {("hexe_lilli", "apple_music", "a2"): "4001504265618"}

    assert record_barcodes(result) == 1

    albums = json.loads(curation_path("hexe_lilli").read_text())["albums"]
    assert [a["barcode"] for a in albums] == ["4001504265595", "4001504265618"]
