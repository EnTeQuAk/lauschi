"""An episode number comes from the title or the track names, or not at all.

The finalize agent used to read track listings and hand back numbers
for unnumbered albums; on Wieso? Weshalb? Warum? one clean run set 66,
38 and 33 that way and the next set none (panel, 2026-09-06). Chris:
"it's either track numbers from metadata, or track names via the regex
we already use, or release date; nothing else should be derived or
guessed." So the series pattern is applied to the track names in code;
when they agree on exactly one number it is the number, otherwise the
album stays unnumbered and the app orders it by release date.
"""

from lauschi_catalog.catalog.curate_ops import _derive_numbers_from_tracks
from tests.factories import decision

PATTERN = r"Folge (\d+)"


def _details(album_id, *names, provider="apple_music"):
    return {f"{provider}:{album_id}": {"tracks": [{"name": n} for n in names]}}


def test_tracks_that_agree_on_one_number_set_it():
    d = decision("x", provider="apple_music", title="Wir entdecken Kleidung")
    details = _details("x", "Folge 66 - Kapitel 1", "Folge 66 - Kapitel 2", "Abspann")
    assert _derive_numbers_from_tracks([d], details, PATTERN) == 1
    assert d.episode_num == 66


def test_tracks_that_disagree_leave_the_album_unnumbered():
    d = decision("box", provider="apple_music", title="Sammelbox")
    details = _details("box", "Folge 12 - Teil 1", "Folge 13 - Teil 1")
    assert _derive_numbers_from_tracks([d], details, PATTERN) == 0
    assert d.episode_num is None


def test_tracks_without_a_number_leave_the_album_unnumbered():
    d = decision("y", provider="apple_music", title="Alles über Piraten")
    details = _details("y", "Kapitel 1", "Kapitel 2")
    assert _derive_numbers_from_tracks([d], details, PATTERN) == 0
    assert d.episode_num is None


def test_numbered_and_excluded_albums_are_left_alone():
    numbered = decision("n", provider="apple_music", title="Folge 3: X", episode_num=3)
    excluded = decision("e", provider="apple_music", title="Best of", include=False)
    details = {
        **_details("n", "Folge 99 - Teil 1"),
        **_details("e", "Folge 7 - Teil 1"),
    }
    assert _derive_numbers_from_tracks([numbered, excluded], details, PATTERN) == 0
    assert numbered.episode_num == 3 and excluded.episode_num is None


def test_no_pattern_or_no_details_means_nothing_happens():
    d = decision("x", provider="apple_music", title="Ohne Muster")
    assert _derive_numbers_from_tracks([d], {}, PATTERN) == 0
    assert _derive_numbers_from_tracks([d], _details("x", "Folge 5"), None) == 0
    assert d.episode_num is None
