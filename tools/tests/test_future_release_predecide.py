"""A not-yet-released album is excluded deterministically, not judged.

An Apple album dated 2026-10-02 made two clean Kira runs disagree: one
excluded it, one included it reasoning the future date was a data
error. For a children's catalog a pre-release must not ship, and the
decision must be the same every run, so it is settled in code before
the batch phase sees the album.
"""

from datetime import date

from lauschi_catalog.catalog.curate_ops import _pre_decide_future_releases


def _album(album_id, release_date, provider="spotify"):
    return {
        "provider": provider,
        "id": album_id,
        "name": f"Folge X {album_id}",
        "release_date": release_date,
    }


TODAY = date(2026, 9, 5)


def test_a_future_dated_album_is_pre_excluded():
    remaining = [_album("future", "2026-10-02"), _album("past", "2024-01-01")]
    decided, still = _pre_decide_future_releases(remaining, today=TODAY)
    assert [d.album_id for d in decided] == ["future"]
    assert decided[0].include is False
    assert decided[0].exclude_reason == "partial_release"
    assert [a["id"] for a in still] == ["past"]


def test_todays_release_is_not_future():
    remaining = [_album("today", "2026-09-05")]
    decided, still = _pre_decide_future_releases(remaining, today=TODAY)
    assert decided == []
    assert [a["id"] for a in still] == ["today"]


def test_year_only_and_missing_dates_are_left_to_the_batch():
    remaining = [_album("yr", "2026"), _album("none", ""), _album("null", None)]
    decided, still = _pre_decide_future_releases(remaining, today=TODAY)
    assert decided == []
    assert len(still) == 3


def test_future_album_on_both_providers_is_excluded_on_both():
    remaining = [
        _album("x", "2026-12-01", provider="spotify"),
        _album("x", "2026-12-01", provider="apple_music"),
    ]
    decided, still = _pre_decide_future_releases(remaining, today=TODAY)
    assert {d.provider for d in decided} == {"spotify", "apple_music"}
    assert still == []
