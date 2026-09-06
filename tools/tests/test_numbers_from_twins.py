"""An album without a number in its own title takes the number its twin
on the other provider carries.

Apple ships Wieso? Weshalb? Warum? episode 15 as "Alles über
Prinzessinnen", Spotify as "Alles über Prinzessinnen (Wieso? Weshalb?
Warum? Folge 15)", same release date. The twin's title is provider
metadata like our own, so the number comes from metadata, not from a
guess. A twin is the same core title on the other provider with the
same release date; the twins must agree on one number.
"""

from lauschi_catalog.catalog.curate_ops import _derive_numbers_from_twins, core_title
from tests.factories import decision

NAMES = ["Wieso? Weshalb? Warum?"]


def test_the_twins_number_fills_a_title_without_one():
    apple = decision(
        "a",
        provider="apple_music",
        title="Alles über Prinzessinnen",
        release_date="2014-07-24",
    )
    spotify = decision(
        "s",
        provider="spotify",
        title="Alles über Prinzessinnen (Wieso? Weshalb? Warum? Folge 15)",
        release_date="2014-07-24",
        episode_num=15,
    )
    assert _derive_numbers_from_twins([apple, spotify], NAMES) == 1
    assert apple.episode_num == 15


def test_a_different_release_date_is_not_a_twin():
    apple = decision(
        "a",
        provider="apple_music",
        title="Alles über Prinzessinnen",
        release_date="2007-01-01",
    )
    spotify = decision(
        "s",
        provider="spotify",
        title="Alles über Prinzessinnen",
        release_date="2014-07-24",
        episode_num=15,
    )
    assert _derive_numbers_from_twins([apple, spotify], NAMES) == 0
    assert apple.episode_num is None


def test_twins_that_disagree_number_nothing():
    apple = decision(
        "a", provider="apple_music", title="Ozeane", release_date="2020-01-01"
    )
    one = decision(
        "s1",
        provider="spotify",
        title="Ozeane",
        release_date="2020-01-01",
        episode_num=3,
    )
    two = decision(
        "s2",
        provider="spotify",
        title="Ozeane",
        release_date="2020-01-01",
        episode_num=8,
    )
    assert _derive_numbers_from_twins([apple, one, two], NAMES) == 0
    assert apple.episode_num is None


def test_excluded_and_same_provider_records_are_not_twins():
    apple = decision(
        "a", provider="apple_music", title="Ozeane", release_date="2020-01-01"
    )
    gone = decision(
        "s",
        provider="spotify",
        title="Ozeane",
        release_date="2020-01-01",
        include=False,
        episode_num=3,
    )
    same = decision(
        "b",
        provider="apple_music",
        title="Ozeane",
        release_date="2020-01-01",
        episode_num=3,
    )
    assert _derive_numbers_from_twins([apple, gone, same], NAMES) == 0


def test_an_unclosed_series_parenthetical_is_stripped_too():
    """Providers truncate long titles: the closing parenthesis is gone."""
    assert (
        core_title(
            "Alles über Laster, Bagger und Traktoren (Wieso? Weshalb? Warum? Folge 38",
            NAMES,
        )
        == "alles über laster, bagger und traktoren"
    )
