"""A carried episode number survives a re-curation only if the title or
the track names still support it.

`curate --force` carries prior decisions forward, numbers included, and
the deterministic extraction only sets a number where the pattern
matches, so a number the model once guessed would live forever. Chris's
rule: a number comes from the title or the track names via the pattern,
or from nothing. So after extraction, an included album whose title
does not match and whose known tracks carry no number loses the number.
An album whose tracks are unknown keeps it: dropping on missing data
would be a guess in the other direction.
"""

from lauschi_catalog.catalog.curate_ops import _drop_unsupported_numbers
from tests.factories import decision

PATTERN = r"Folge (\d+)"


def _tracks(album_id, *names, provider="apple_music"):
    return {f"{provider}:{album_id}": {"tracks": [{"name": n} for n in names]}}


def test_a_carried_number_without_title_or_track_support_is_dropped():
    d = decision("x", provider="apple_music", title="Alles über Laster", episode_num=38)
    assert (
        _drop_unsupported_numbers([d], _tracks("x", "Kapitel 1", "Kapitel 2"), PATTERN)
        == 1
    )
    assert d.episode_num is None


def test_a_number_the_title_supports_stays():
    d = decision(
        "x", provider="apple_music", title="Folge 12: Der Fluch", episode_num=12
    )
    assert _drop_unsupported_numbers([d], _tracks("x", "Kapitel 1"), PATTERN) == 0
    assert d.episode_num == 12


def test_a_number_the_tracks_support_stays():
    d = decision(
        "x", provider="apple_music", title="Wir entdecken Kleidung", episode_num=66
    )
    assert (
        _drop_unsupported_numbers([d], _tracks("x", "Folge 66 - Teil 1"), PATTERN) == 0
    )
    assert d.episode_num == 66


def test_unknown_tracks_keep_the_number():
    d = decision("x", provider="apple_music", title="Ohne Nummer", episode_num=7)
    assert _drop_unsupported_numbers([d], {}, PATTERN) == 0
    assert d.episode_num == 7


def test_excluded_and_unnumbered_albums_are_untouched():
    a = decision(
        "a", provider="apple_music", title="Ohne", include=False, episode_num=3
    )
    b = decision("b", provider="apple_music", title="Ohne")
    assert _drop_unsupported_numbers([a, b], _tracks("a", "Kapitel 1"), PATTERN) == 0
    assert a.episode_num == 3 and b.episode_num is None
