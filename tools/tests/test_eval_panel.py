"""Two curations of the same series are compared decision by decision.

The determinism panel runs a series twice from a clean directory and
asks whether anything a child would notice changed: an include flag, an
episode number. Reason labels on excluded albums are reported apart,
because they change what a reviewer reads, not what ships.
"""

from lauschi_catalog.eval.panel import diff_curations
from tests.factories import album_record


def _album(aid, include, ep=None, reason=None, provider="spotify"):
    return album_record(
        aid, provider=provider, include=include, episode_num=ep, exclude_reason=reason
    )


def test_identical_runs_have_no_differences():
    a = {"albums": [_album("x", True, 1), _album("y", False, None, "compilation")]}
    d = diff_curations(a, a)
    assert d.include_flips == () and d.episode_diffs == () and d.reason_diffs == ()
    assert d.only_a == () and d.only_b == ()
    assert d.identical


def test_an_include_flip_is_reported_with_both_sides():
    a = {"albums": [_album("x", True, 1)]}
    b = {"albums": [_album("x", False, 1, "sub_series_bleed")]}
    d = diff_curations(a, b)
    assert d.include_flips == (("spotify", "x", True, False),)
    assert not d.identical


def test_episode_and_reason_differences_are_kept_apart():
    a = {"albums": [_album("x", True, 1), _album("y", False, None, "compilation")]}
    b = {
        "albums": [_album("x", True, 2), _album("y", False, None, "wrong_content_type")]
    }
    d = diff_curations(a, b)
    assert d.episode_diffs == (("spotify", "x", 1, 2),)
    assert d.reason_diffs == (("spotify", "y", "compilation", "wrong_content_type"),)
    assert d.include_flips == ()


def test_albums_present_on_one_side_only_are_listed():
    a = {"albums": [_album("x", True, 1), _album("only_a", True, 2)]}
    b = {"albums": [_album("x", True, 1), _album("only_b", True, 3)]}
    d = diff_curations(a, b)
    assert d.only_a == (("spotify", "only_a"),)
    assert d.only_b == (("spotify", "only_b"),)


def test_same_id_on_two_providers_is_two_albums():
    a = {
        "albums": [
            _album("x", True, 1, provider="spotify"),
            _album("x", True, 1, provider="apple_music"),
        ]
    }
    b = {
        "albums": [
            _album("x", True, 1, provider="spotify"),
            _album("x", False, 1, "duplicate", provider="apple_music"),
        ]
    }
    d = diff_curations(a, b)
    assert d.include_flips == (("apple_music", "x", True, False),)
