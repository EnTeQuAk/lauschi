"""An album's barcode travels from the provider record to series.yaml.

Curate puts the provider's barcode on every decision, as it does the
title and release date, a re-curation carries it, and apply writes it
next to the album id. It names the release on both stores and in the
reference index, so a store id that moved to another release shows.
"""

from pathlib import Path

from ruamel.yaml import YAML

from lauschi_catalog.catalog.apply_ops import apply_one
from lauschi_catalog.catalog.curate_ops import (
    _fill_barcodes,
    _preseed_decisions,
    _restore_identity,
)
from lauschi_catalog.catalog.loader import _parse_catalog
from lauschi_catalog.providers.base import Album
from tests.factories import album_record, decision, discovered_album


def test_a_decision_takes_the_barcode_of_its_provider_record() -> None:
    found = discovered_album("spotify", "s1", "Folge 1: Der Sturm")
    found["barcode"] = "4029759160373"
    decided = [decision("s1", title="Folge 1: Der Sturm", episode_num=1)]

    assert _restore_identity(decided, [found], r"^Folge (\d+):") == 0
    assert decided[0].barcode == "4029759160373"


def test_the_artist_page_gets_the_barcode_of_the_full_record() -> None:
    """Spotify's artist page lists no barcode, its full album record does."""
    listed = [
        discovered_album("spotify", "s1"),
        discovered_album("apple_music", "a1") | {"barcode": "190295911126"},
    ]
    full = {
        "spotify:s1": Album("s1", "Folge 1", "spotify", barcode="4029759160373"),
        "apple_music:a1": Album("a1", "Folge 1", "apple_music", barcode="999"),
    }

    _fill_barcodes(listed, full)

    assert [a["barcode"] for a in listed] == ["4029759160373", "190295911126"]


def test_a_carried_decision_keeps_its_barcode() -> None:
    existing = {"albums": [album_record("s1", barcode="4029759160373")]}
    carried, _ = _preseed_decisions([discovered_album("spotify", "s1")], existing)
    assert carried[0].barcode == "4029759160373"


def _yaml_entry(*albums: dict) -> dict:
    return {
        "id": "s",
        "title": "S",
        "providers": {"spotify": {"albums": list(albums)}},
    }


def _curation(*albums: dict) -> dict:
    return {"id": "s", "title": "S", "albums": list(albums)}


def test_apply_writes_the_barcode_next_to_the_album_id() -> None:
    yaml_data = {"series": [_yaml_entry()]}
    data = _curation(
        album_record("s1", title="Folge 1", episode_num=1, barcode="4029759160373"),
        album_record("s2", title="Folge 2", episode_num=2, barcode=""),
    )

    assert apply_one("s", data, yaml_data)

    assert yaml_data["series"][0]["providers"]["spotify"]["albums"] == [
        {"id": "s1", "episode": 1, "title": "Folge 1", "barcode": "4029759160373"},
        {"id": "s2", "episode": 2, "title": "Folge 2"},
    ]


def test_apply_writes_a_barcode_that_is_all_that_changed() -> None:
    shipped = {"id": "s1", "episode": 1, "title": "Folge 1"}
    yaml_data = {"series": [_yaml_entry(shipped)]}
    data = _curation(
        album_record("s1", title="Folge 1", episode_num=1, barcode="4029759160373")
    )

    assert apply_one("s", data, yaml_data)
    album = yaml_data["series"][0]["providers"]["spotify"]["albums"][0]
    assert album["barcode"] == "4029759160373"


def test_the_catalog_reads_the_barcode(tmp_path: Path) -> None:
    path = tmp_path / "series.yaml"
    YAML().dump(
        {
            "series": [
                _yaml_entry(
                    {"id": "s1", "episode": 1, "title": "Folge 1", "barcode": "0123"},
                    {"id": "s2", "episode": 2, "title": "Folge 2"},
                )
            ]
        },
        path,
    )

    (entry,) = _parse_catalog(path)

    assert [a["barcode"] for a in entry.providers["spotify"].albums] == ["0123", ""]
