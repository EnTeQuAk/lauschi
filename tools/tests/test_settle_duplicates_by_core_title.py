"""Unnumbered twins on one provider are settled by the series' own name.

Wieso? Weshalb? Warum? on Apple ships "Wieso? Weshalb? Warum? Alles über
die Feuerwehr" (2011) next to "Alles über die Feuerwehr (Wieso? Weshalb?
Warum? Folge 2)" (2011): the same episode twice, once titled with the
brand as a prefix, once with brand and number as a suffix. Stripping the
series' own name (a catalog fact) makes the cores equal; with no era
between them the numbered one is kept.
"""

from lauschi_catalog.catalog.curate_ops import (
    SeriesMetadata,
    _series_names,
    _settle_same_provider_duplicates,
    core_title,
)
from tests.factories import decision, entry

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


def test_a_re_release_with_a_zero_padded_number_is_a_duplicate():
    """SpongeBob's stories come out again since 2026 as "Folge 001: ...",
    next to the "Folge 1: ..." of 2020. The padding made them two titles,
    and both shipped, the older one without its number."""
    old = decision(
        "old",
        provider="apple_music",
        title="Folge 1: Aushilfe gesucht (Das Original-Hörspiel zur TV-Serie) - EP",
        release_date="2020-04-03",
    )
    new = decision(
        "new",
        provider="apple_music",
        title="Folge 001: Aushilfe gesucht (Das Original-Hörspiel zur TV-Serie) - EP",
        episode_num=1,
        release_date="2026-07-03",
    )
    out = {
        d.album_id: d
        for d in _settle_same_provider_duplicates(
            [old, new], [], series_names=["SpongeBob Schwammkopf"]
        )
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


def test_the_names_of_a_catalog_entry_are_its_title_and_aliases():
    line = entry("www", "Wieso? Weshalb? Warum?", aliases=["WWW"])
    meta = SeriesMetadata(id="www", title="Wieso? Weshalb? Warum?", aliases=["Wissen"])

    assert _series_names(meta, line) == ["Wieso? Weshalb? Warum?", "WWW"]


def test_a_series_the_catalog_does_not_hold_is_named_by_its_title_alone():
    meta = SeriesMetadata(id="tintenwelt", title="Tintenwelt", aliases=["Tintenherz"])

    assert _series_names(meta, None) == ["Tintenwelt"]


def test_an_alias_the_run_proposes_does_not_make_two_albums_one():
    """The metadata agent named the three books as aliases of Tintenwelt,
    and album titles as aliases of Giraffenaffen. Stripped of those, the
    albums had one title left between them, and the settle kept the newest
    as the only release: Tintenherz and Tintentod went out as duplicates of
    Tintenblut, Giraffenaffen 1 to 9 as duplicates of Giraffenaffen 10."""
    line = entry("tintenwelt", "Tintenwelt")
    meta = SeriesMetadata(
        id="tintenwelt",
        title="Tintenwelt",
        aliases=["Tintenherz", "Tintenblut", "Tintentod"],
    )
    herz = decision(
        "herz", title="Tintenherz - Das Hörspiel", release_date="2013-08-01"
    )
    blut = decision(
        "blut", title="Tintenblut - Das Hörspiel", release_date="2014-07-21"
    )

    settled = _settle_same_provider_duplicates(
        [herz, blut], [], series_names=_series_names(meta, line)
    )

    assert all(d.include for d in settled)


def test_two_films_whose_titles_leave_only_decoration_are_both_kept():
    """Sing's alias is its second film's title. Stripped of "Sing" and of
    "Sing - Die Show deines Lebens", both Hörspiele left the same
    "(Das Original-Hörspiel zum Kinofilm)", and the first film went out
    as a duplicate of the second (2026-10-14). What is left outside the
    parentheses names the episode, and here nothing is."""
    names = ["Sing", "Sing - Die Show deines Lebens"]
    first = decision(
        "first",
        title="Sing (Das Original-Hörspiel zum Kinofilm)",
        release_date="2021-12-03",
    )
    second = decision(
        "second",
        title="Sing - Die Show deines Lebens (Das Original-Hörspiel zum Kinofilm)",
        release_date="2022-02-18",
    )
    out = _settle_same_provider_duplicates([first, second], [], series_names=names)
    assert [d.include for d in out] == [True, True]
    assert core_title(first.title, names) == "sing (das original-hörspiel zum kinofilm)"
