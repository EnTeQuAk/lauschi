"""New releases on a shared artist page are routed by the family's own patterns.

Two clean curations of the LEGO Ninjago Hörbuch child (2026-09-06) both
excluded the line's eight new "(Band 13-20)" books as sub_series_bleed,
and one of them pulled in three new "Folge 268-270" parent episodes. The
model was guessing which member of the family a new album belongs to.
Every member's episode_pattern is a catalog fact: an undecided album that
matches exactly one member's pattern belongs to that member. Matching the
current entry's pattern means include with the captured number; matching
another member's means exclude as sub_series_bleed; matching none or
several means the model decides.
"""

from lauschi_catalog.catalog.curate_ops import _route_by_family_patterns
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from tests.factories import discovered_album

PARENT = CatalogEntry(
    id="lego_ninjago",
    title="LEGO Ninjago",
    episode_pattern=r"^Folge (\d+):",
    providers={"spotify": ProviderConfig(artist_ids=["art"])},
)
CHILD = CatalogEntry(
    id="lego_ninjago_hoerbuch",
    title="LEGO Ninjago: Hörbücher",
    split_from="lego_ninjago",
    episode_pattern=r"\(Band (\d+)\)",
    providers={"spotify": ProviderConfig(artist_ids=["art"])},
)
FILM = CatalogEntry(
    id="lego_ninjago_kinofilm",
    title="LEGO Ninjago: Kinofilm",
    split_from="lego_ninjago",
    providers={"spotify": ProviderConfig(artist_ids=["art"])},
)
FAMILY = [PARENT, CHILD, FILM]


def _remaining():
    return [
        discovered_album("spotify", "b16", "Zane (Band 16)"),
        discovered_album(
            "spotify", "f268", "Folge 268: Wenn die letzte Stunde schlägt"
        ),
        discovered_album("spotify", "film", "Der Film"),
    ]


def test_the_child_run_keeps_its_line_and_hands_the_parents_episode_back():
    decided, still = _route_by_family_patterns(_remaining(), CHILD, FAMILY)
    by = {d.album_id: d for d in decided}
    assert by["b16"].include is True and by["b16"].episode_num == 16
    assert (
        by["f268"].include is False and by["f268"].exclude_reason == "sub_series_bleed"
    )
    assert "lego_ninjago" in (by["f268"].notes or "")
    assert [a["id"] for a in still] == ["film"]


def test_the_parent_run_hands_the_childs_new_book_to_the_child_and_judges_its_own():
    """A pattern proves ownership, not validity: on the parent, titles
    matching its own pattern still go to the model, which judges
    compilations, variants and duplicates among them. Only a child's
    narrow line is included by its pattern alone."""
    decided, still = _route_by_family_patterns(_remaining(), PARENT, FAMILY)
    by = {d.album_id: d for d in decided}
    assert set(by) == {"b16"}
    assert by["b16"].include is False and "lego_ninjago_hoerbuch" in (
        by["b16"].notes or ""
    )
    assert [a["id"] for a in still] == ["f268", "film"]


def test_an_album_matching_two_members_is_left_to_the_model():
    twin = CatalogEntry(
        id="lego_ninjago_junior",
        title="LEGO Ninjago Junior",
        split_from="lego_ninjago",
        episode_pattern=r"^Folge (\d+):",
    )
    decided, still = _route_by_family_patterns(_remaining(), PARENT, FAMILY + [twin])
    assert "f268" not in {d.album_id for d in decided}
    assert "f268" in [a["id"] for a in still]


def test_a_series_without_a_family_routes_nothing():
    lone = CatalogEntry(id="conni", title="Conni", episode_pattern=r"^Folge (\d+):")
    decided, still = _route_by_family_patterns(_remaining(), lone, [lone])
    assert decided == [] and len(still) == 3
