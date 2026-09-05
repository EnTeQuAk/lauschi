"""An album's title and release date come from the provider, not the model.

The batch model returns the right album id but echoes the title back,
and on a run of similar titles it slips by one: two clean LEGO Ninjago
runs (2026-09-05) saved 18 and 14 wrong titles for right ids, and the
episode number followed the wrong title. Applied, that ships a tile that
plays a different episode than it names. Identity fields are restored
from the discovery record by id; a number that came from a wrong title
is re-derived from the true one.
"""

from lauschi_catalog.catalog.curate_ops import _restore_identity
from tests.factories import decision, discovered_album

PATTERN = r"^Folge (\d+):"


def _found(provider, album_id, name, release_date=None):
    a = discovered_album(provider, album_id, name)
    a["release_date"] = release_date
    return a


def test_a_swapped_title_is_restored_and_the_number_follows_the_true_title():
    found = [
        _found("apple_music", "59", "Folge 27: Das neue Ninjago", "2020-04-21"),
        _found(
            "apple_music",
            "15",
            "Folge 26: Der ultimative Spinjitzu-Meister",
            "2020-04-21",
        ),
    ]
    decided = [
        decision(
            "59",
            provider="apple_music",
            title="Folge 26: Der ultimative Spinjitzu-Meister",
            episode_num=26,
        ),
        decision(
            "15",
            provider="apple_music",
            title="Folge 27: Das neue Ninjago",
            episode_num=27,
        ),
    ]
    fixed = _restore_identity(decided, found, PATTERN)
    assert fixed == 2
    by = {d.album_id: d for d in decided}
    assert by["59"].title == "Folge 27: Das neue Ninjago" and by["59"].episode_num == 27
    assert (
        by["15"].title == "Folge 26: Der ultimative Spinjitzu-Meister"
        and by["15"].episode_num == 26
    )
    assert by["59"].release_date == "2020-04-21"


def test_a_correct_echo_is_left_alone_including_a_model_chosen_number():
    found = [_found("spotify", "x", "Staffel 3, Episode 1: Neue Zeiten")]
    decided = [decision("x", title="Staffel 3, Episode 1: Neue Zeiten", episode_num=27)]
    assert _restore_identity(decided, found, r"Episode (\d+):") == 0
    assert decided[0].episode_num == 27


def test_a_wrong_title_whose_true_title_has_no_number_drops_the_number():
    found = [_found("spotify", "x", "Der Super-Papagei")]
    decided = [decision("x", title="Folge 3: Der Super-Papagei", episode_num=3)]
    assert _restore_identity(decided, found, PATTERN) == 1
    assert decided[0].title == "Der Super-Papagei" and decided[0].episode_num is None


def test_an_id_the_discovery_never_produced_is_untouched():
    decided = [decision("ghost", title="Folge 9: Nichts", episode_num=9)]
    assert _restore_identity(decided, [], PATTERN) == 0
    assert decided[0].title == "Folge 9: Nichts"
