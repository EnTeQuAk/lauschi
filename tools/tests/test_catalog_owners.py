"""An album that ships in another catalog series belongs to that series.

Each Astrid Lindgren child carried Ferien auf Saltkrokan albums and each
Cornelia Funke child Wilde Hühner ones as ownerless bleed (2026-09-30):
the series share an artist page but not a family. Which series ships an
album is a catalog fact, so ownership follows it, family or not.
"""

from lauschi_catalog.catalog.curate_ops import (
    _name_catalog_owners,
    _route_to_catalog_owners,
)
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.partition import bleed_owner, catalog_album_owners
from tests.factories import decision


def _entry(sid: str, *album_ids: str) -> CatalogEntry:
    albums = [{"id": i, "title": f"Titel {i}"} for i in album_ids]
    return CatalogEntry(
        id=sid,
        title=sid,
        providers={
            "spotify": ProviderConfig(
                artist_ids=["lindgren"], album_ids=list(album_ids), albums=albums
            )
        },
    )


CATALOG = [
    _entry("madita", "m1"),
    _entry("ferien_auf_saltkrokan", "s1", "s2"),
    _entry("pippi", "p1", "shared"),
    _entry("michel", "shared"),
]


def test_owners_are_the_other_series_that_ship_the_album() -> None:
    owners = catalog_album_owners(CATALOG, "madita")
    assert owners[("spotify", "s1")] == "ferien_auf_saltkrokan"
    assert ("spotify", "m1") not in owners
    # shipped by two other series: no single owner to name
    assert ("spotify", "shared") not in owners


def test_an_undecided_album_another_series_ships_is_its_bleed() -> None:
    owners = catalog_album_owners(CATALOG, "madita")
    remaining = [
        {"provider": "spotify", "id": "s1", "name": "Ferien auf Saltkrokan 1"},
        {"provider": "spotify", "id": "new", "name": "Madita 9"},
    ]
    decided, still = _route_to_catalog_owners(remaining, owners)
    assert [a["id"] for a in still] == ["new"]
    (d,) = decided
    assert (d.album_id, d.include, d.exclude_reason) == (
        "s1",
        False,
        "sub_series_bleed",
    )
    assert bleed_owner(d.notes) == "ferien_auf_saltkrokan"
    assert d.decided_by == "route"


def test_a_carried_ownerless_exclusion_names_its_owner() -> None:
    owners = catalog_album_owners(CATALOG, "madita")
    stray = decision("s1", include=False, exclude_reason="sub_series_bleed")
    kept_in = decision("s2", include=True)
    operator = decision("p1", include=False, exclude_reason="sub_series_bleed")
    operator.decided_by = "operator"
    named = _name_catalog_owners([stray, kept_in, operator], owners)
    assert named == 1
    assert bleed_owner(stray.notes) == "ferien_auf_saltkrokan"
    assert kept_in.include and not kept_in.notes
    assert bleed_owner(operator.notes) is None
