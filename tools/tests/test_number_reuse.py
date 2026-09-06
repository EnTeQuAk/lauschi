"""A number two different stories carry stays with the newest of them.

Wieso? Weshalb? Warum? reuses numbers across its eras: "Alles über
Piraten" (2007) and "Abenteurer und Entdecker" (2019) are both Folge
40 in their titles. The app shows one tile per number, and Chris
settled the August pairs by hand: the current holder keeps the number.
Release date is the fact that decides; the older story keeps its
title and loses the number. Same-title twins are the duplicate
settle's business, not this one's.
"""

from lauschi_catalog.catalog.curate_ops import _settle_number_reuse
from tests.factories import decision

NAMES = ["Wieso? Weshalb? Warum?"]


def test_the_newest_story_keeps_a_reused_number():
    old = decision(
        "o",
        title="Alles über Piraten (Wieso? Weshalb? Warum? Folge 40)",
        episode_num=40,
        release_date="2007-01-01",
    )
    new = decision(
        "n",
        title="Abenteurer und Entdecker (Wieso? Weshalb? Warum? Folge 40)",
        episode_num=40,
        release_date="2019-01-01",
    )
    assert _settle_number_reuse([old, new], NAMES) == 1
    assert (old.episode_num, new.episode_num) == (None, 40)
    assert "reused" in (old.notes or "")


def test_same_story_twins_are_left_to_the_duplicate_settle():
    a = decision(
        "a",
        title="Alles über Piraten (Wieso? Weshalb? Warum? Folge 40)",
        episode_num=40,
        release_date="2007-01-01",
    )
    b = decision(
        "b",
        title="Wieso? Weshalb? Warum? Alles über Piraten",
        episode_num=40,
        release_date="2015-01-01",
    )
    assert _settle_number_reuse([a, b], NAMES) == 0
    assert a.episode_num == 40 and b.episode_num == 40


def test_providers_are_settled_apart_and_excluded_records_do_not_count():
    apple = decision(
        "a",
        provider="apple_music",
        title="Piraten (Folge 40)",
        episode_num=40,
        release_date="2007-01-01",
    )
    spotify = decision(
        "s",
        provider="spotify",
        title="Entdecker (Folge 40)",
        episode_num=40,
        release_date="2019-01-01",
    )
    gone = decision(
        "g",
        provider="spotify",
        title="Ritter (Folge 40)",
        episode_num=40,
        release_date="2021-01-01",
        include=False,
        exclude_reason="duplicate",
    )
    assert _settle_number_reuse([apple, spotify, gone], NAMES) == 0


def test_without_release_dates_nothing_is_decided():
    a = decision("a", title="Piraten (Folge 40)", episode_num=40)
    b = decision("b", title="Entdecker (Folge 40)", episode_num=40)
    assert _settle_number_reuse([a, b], NAMES) == 0
