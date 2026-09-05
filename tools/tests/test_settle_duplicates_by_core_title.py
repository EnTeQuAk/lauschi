"""Unnumbered twins on one provider are settled by the series' own name.

Wieso? Weshalb? Warum? on Apple ships "Wieso? Weshalb? Warum? Alles über
die Feuerwehr" (2011) next to "Alles über die Feuerwehr (Wieso? Weshalb?
Warum? Folge 2)" (2011): the same episode twice, once titled with the
brand as a prefix, once with brand and number as a suffix. Stripping the
series' own name (a catalog fact) makes the cores equal; with no era
between them the numbered one is kept.
"""

from lauschi_catalog.catalog.curate_ops import (
    _settle_same_provider_duplicates,
    core_title,
)
from tests.factories import decision

NAMES = ["Wieso? Weshalb? Warum?", "WWW"]


def test_core_title_strips_the_series_name_as_prefix_or_parenthetical():
    assert (
        core_title("Wieso? Weshalb? Warum? Alles über die Feuerwehr", NAMES)
        == "alles über die feuerwehr"
    )
    assert (
        core_title("Alles über die Feuerwehr (Wieso? Weshalb? Warum? Folge 2)", NAMES)
        == "alles über die feuerwehr"
    )
    assert core_title("Folge 12: Der Fluch", NAMES) == "folge 12: der fluch"


def test_an_unnumbered_twin_of_a_numbered_episode_is_a_duplicate():
    old = decision(
        "old",
        provider="apple_music",
        title="Wieso? Weshalb? Warum? Alles über die Feuerwehr",
        release_date="2011-01-01",
    )
    new = decision(
        "new",
        provider="apple_music",
        title="Alles über die Feuerwehr (Wieso? Weshalb? Warum? Folge 2)",
        episode_num=2,
        release_date="2011-01-01",
    )
    out = {
        d.album_id: d
        for d in _settle_same_provider_duplicates([old, new], [], series_names=NAMES)
    }
    assert out["new"].include is True
    assert out["old"].include is False and out["old"].exclude_reason == "duplicate"


def test_two_different_episodes_sharing_a_core_title_are_both_kept():
    a = decision("a", title="Folge 28: Das innere Gleichgewicht", episode_num=28)
    b = decision("b", title="Folge 29: Das innere Gleichgewicht", episode_num=29)
    assert all(
        d.include
        for d in _settle_same_provider_duplicates(
            [a, b], [], series_names=["LEGO Ninjago"]
        )
    )


def test_without_series_names_numbered_behaviour_is_unchanged():
    old = decision(
        "old", title="Folge 12: Der Fluch", episode_num=12, release_date="1985-01-01"
    )
    new = decision(
        "new", title="Folge 12: Der Fluch", episode_num=12, release_date="2019-01-01"
    )
    out = {d.album_id: d for d in _settle_same_provider_duplicates([old, new], [])}
    assert out["new"].include is True and out["old"].include is False
