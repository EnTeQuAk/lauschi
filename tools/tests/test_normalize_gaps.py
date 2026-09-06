"""A known_gap whose episode is included is not a gap any more.

Sixty gap facts on thirty series named an episode as missing after it
had been released and included (Teufelskicker Folge 111, 2026). The
normalise pass drops them, only where the series has at most one era so
a classic-versus-new numbering clash cannot fool it.
"""

from lauschi_catalog.catalog.reconcile import drop_stale_known_gaps
from tests.factories import album_record, curation


def _facts(gaps, eras=()):
    return {
        "known_gaps": [
            {"number": n, "reason": "r", "curated_by": "curate"} for n in gaps
        ],
        "era_boundaries": [
            {"label": f"e{i}", "release_date_range": r, "curated_by": "curate"}
            for i, r in enumerate(eras)
        ],
    }


def test_a_gap_whose_number_is_included_is_dropped():
    c = curation(
        albums=[album_record("a", episode_num=111)], series_facts=_facts([111, 112])
    )
    assert drop_stale_known_gaps(c) == 1
    assert [g["number"] for g in c["series_facts"]["known_gaps"]] == [112]


def test_a_real_gap_stays():
    c = curation(albums=[album_record("a", episode_num=4)], series_facts=_facts([5]))
    assert drop_stale_known_gaps(c) == 0


def test_several_eras_leave_gaps_alone():
    c = curation(
        albums=[album_record("a", episode_num=1)],
        series_facts=_facts([1], eras=["1980-1990", "2020-"]),
    )
    assert drop_stale_known_gaps(c) == 0


def test_no_facts_is_fine():
    assert (
        drop_stale_known_gaps(curation(albums=[album_record("a", episode_num=1)])) == 0
    )
