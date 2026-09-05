"""Finalize is handed the sub-series exclusions with their ids.

Told only a count and "use search_excluded_albums to explore", the
finalize agent on Bibi und Tina searched keyword by keyword for the 16
titles until it hit the 200-request budget (2026-09-05). The pipeline
holds every one of those records; it lists them, so a split proposal
needs no search.
"""

from lauschi_catalog.catalog.curate_ops import render_sub_series_exclusions


def test_titles_are_listed_with_their_ids_grouped_by_title():
    records = {
        "Bibi und Tina: Kinofilm 1": [("spotify", "s1"), ("apple_music", "a1")],
        "BFF Talk: Folge 1": [("spotify", "s2")],
    }
    text = render_sub_series_exclusions(records)
    assert '"Bibi und Tina: Kinofilm 1" [spotify:s1, apple_music:a1]' in text
    assert '"BFF Talk: Folge 1" [spotify:s2]' in text
    assert "no search needed" in text


def test_a_long_list_is_capped_and_says_how_many_more():
    records = {f"Title {i}": [("spotify", f"s{i}")] for i in range(70)}
    text = render_sub_series_exclusions(records, cap=60)
    assert text.count("[spotify:") == 60
    assert "10 more" in text
