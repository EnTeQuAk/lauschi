"""Albums that hold a run of episodes, and what else a page offers of them.

Feuerwehrmann Sam's episodes 1 to 132 exist on the stores only as boxes
("Folgen 6-10: Das Baby im Schafspelz"). The curator saw 30 albums per
batch and could not tell whether the episodes also exist on their own,
so it excluded every box as a compilation and the series lost its first
132 episodes. These tests pin the fact the batch now gets for each box.
"""

import pytest

from lauschi_catalog.catalog.episode_range import (
    EpisodeRange,
    RangeFact,
    episode_range,
    numbers_released_alone,
    range_facts,
)
from tests.factories import decision


@pytest.mark.parametrize(
    ("title", "expected"),
    [
        ("Folgen 6-10: Das Baby im Schafspelz (Die Original-Hörspiele)", (6, 10)),
        ("Folgen 165 - 169: Das doppelte Feuerwerk", (165, 169)),
        ("Folgen 1-4: Wasser Marsch", (1, 4)),
        ("Hörspiele zur Serie (Staffel 1, Episode 6-10)", (6, 10)),
        ("001/Gute-Nacht-Geschichten Folge 1+2 - Die verzauberten Seerosen", (1, 2)),
        ("Folge 13 + 14 - Der Traum der Hexe Alba", (13, 14)),
        ("Folgen 3 & 4: Zwei Abenteuer", (3, 4)),
        ("Folge 7 und 8", (7, 8)),
        ("LEGO City TV-Serie Folgen 1-5: Helden und Räuber", (1, 5)),
    ],
)
def test_reads_the_run_from_the_number_position(
    title: str, expected: tuple[int, int]
) -> None:
    assert episode_range(title) == EpisodeRange(*expected)


@pytest.mark.parametrize(
    "title",
    [
        # One story told in two parts is one episode, not a run.
        "Folge 21: Das Drachenauge, Teil 1 & 2 (Das Original-Hörspiel)",
        "Folge 13: Aller Anfang ist schwer - Teil 1 + 2",
        # Three stories under one number, the series' standard format.
        "Folge 4: Die Elchjagd + zwei weitere Geschichten",
        # A year after a dash is not the end of a run.
        "Folge 12 - 2019",
        "Folge 5: Ein Abenteuer",
        "Die große Hörspielbox",
        # Backwards or empty runs say nothing.
        "Folgen 10-6",
        "Folgen 4-4",
    ],
)
def test_ignores_titles_without_a_run(title: str) -> None:
    assert episode_range(title) is None


def test_range_lists_its_episodes() -> None:
    assert EpisodeRange(6, 10).episodes == (6, 7, 8, 9, 10)


def _page_album(album_id: str, name: str, provider: str = "spotify") -> dict[str, str]:
    return {"id": album_id, "provider": provider, "name": name}


PATTERN = r"^Folge (\d+):"


def test_a_box_whose_episodes_exist_nowhere_else_says_so() -> None:
    page = [
        _page_album("box", "Folgen 6-10: Das Baby im Schafspelz"),
        _page_album("single", "Folge 133: Monster-Alarm"),
    ]

    facts = range_facts(page, PATTERN)

    assert facts == {("spotify", "box"): RangeFact(6, 10, released_alone=())}


def test_a_box_lists_the_episodes_the_page_also_has_alone() -> None:
    page = [
        _page_album("box", "Folgen 1-3: Erste Abenteuer"),
        _page_album("one", "Folge 1: Der Anfang"),
        _page_album("three", "Folge 3: Das Ende"),
    ]

    facts = range_facts(page, PATTERN)

    assert facts[("spotify", "box")].released_alone == (1, 3)


def test_each_provider_page_stands_alone() -> None:
    # An Apple Music listener cannot play the Spotify single, so for the
    # Apple box those episodes exist nowhere else.
    page = [
        _page_album("box", "Folgen 1-2: Start", provider="apple_music"),
        _page_album("one", "Folge 1: Der Anfang", provider="spotify"),
        _page_album("two", "Folge 2: Weiter", provider="spotify"),
    ]

    facts = range_facts(page, PATTERN)

    assert facts[("apple_music", "box")].released_alone == ()


def test_numbers_already_decided_count_as_released_alone() -> None:
    # A single whose title the pattern misses still carries the number a
    # prior run gave it, so the fact does not claim the box is alone.
    page = [_page_album("box", "Folgen 1-2: Start")]

    facts = range_facts(page, PATTERN, decided={"spotify": {2}})

    assert facts[("spotify", "box")].released_alone == (2,)


def test_another_box_does_not_count_as_a_release_of_its_own() -> None:
    # Feuerwehrmann Sam has "Folgen 1-4" next to "Folgen 1-5": two boxes
    # of the same episodes are still no single release.
    page = [
        _page_album("a", "Folgen 1-4: Wasser Marsch"),
        _page_album("b", "Folgen 1-5: Der neue Held von Nebenan"),
    ]

    facts = range_facts(page, r"^Folgen? (\d+)")

    assert facts[("spotify", "a")].released_alone == ()
    assert facts[("spotify", "b")].released_alone == ()


def test_without_a_pattern_or_decided_numbers_no_fact_is_given() -> None:
    # "None of them released alone" would be a guess here, and a wrong
    # guess pulls a real compilation into the catalog.
    page = [_page_album("box", "Folgen 1-3: Erste Abenteuer")]

    assert range_facts(page, None) == {}


def test_decided_numbers_count_only_single_releases() -> None:
    # Polly Pocket's "Folgen 1-3" is already included as episode 1. Were
    # that counted, the box would see its own first episode as released
    # alone and the next run would throw it out.
    decisions = [
        decision("box", title="Folgen 1-3: Kleine ganz groß", episode_num=1),
        decision("four", title="Folge 4: Allein", episode_num=4),
        decision("odd", title="Ohne Nummer", episode_num=None),
        decision("am", provider="apple_music", title="Folge 2: Zwei", episode_num=2),
    ]

    assert numbers_released_alone(decisions) == {"spotify": {4}, "apple_music": {2}}
