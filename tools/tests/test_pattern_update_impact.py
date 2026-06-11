"""Pin the deterministic impact report for pattern updates.

Finalize may replace the episode_pattern. The impact report compares
old vs new on two axes: coverage of included titles (episodes that
lose their numbers) and matches on excluded titles (stray digits a
too-broad regex would capture, the gemma-26b merged-regex failure).
Shrinking or denoising is allowed; only a pattern that is both below
the 30% coverage floor AND worse than its predecessor is rejected.
"""

from __future__ import annotations

from lauschi_catalog.catalog.curate_ops import pattern_update_impact

INCLUDED = [
    "Folge 1: Der Anfang",
    "Folge 2: Die Reise",
    "Klassiker, Folge 3: Der Schatz",
    "16/Die fantastischen Vier",
]
EXCLUDED = [
    "Die Biene Maja 2 - Original-Hörspiel zum Kinofilm",
    "Kuschel-Hits Vol. 3",
]


def test_improvement_is_accepted_with_report():
    impact = pattern_update_impact(
        old=["^Folge (\\d+):"],
        new=["^Folge (\\d+):", "^Klassiker, Folge (\\d+):", "^(\\d+)/"],
        included_titles=INCLUDED,
        excluded_titles=EXCLUDED,
    )
    assert impact["rejected"] is None
    assert impact["new_included"] == 4 and impact["old_included"] == 2
    assert "4/4" in impact["report"]


def test_coverage_drop_warns_but_is_allowed():
    impact = pattern_update_impact(
        old=["^Folge (\\d+):", "^(\\d+)/"],
        new=["^Folge (\\d+):"],
        included_titles=INCLUDED,
        excluded_titles=EXCLUDED,
    )
    assert impact["rejected"] is None
    assert "lose" in impact["report"]


def test_excluded_matches_raise_false_positive_warning():
    # unanchored digit grab matches the Kinofilm "2"
    impact = pattern_update_impact(
        old=["^Folge (\\d+):"],
        new=["(\\d+)"],
        included_titles=INCLUDED,
        excluded_titles=EXCLUDED,
    )
    assert impact["new_excluded_matches"] > impact["old_excluded_matches"]
    assert "excluded title" in impact["report"]


def test_below_floor_and_worse_is_rejected():
    impact = pattern_update_impact(
        old=["^Folge (\\d+):"],
        new=["^Episode (\\d+) -"],
        included_titles=INCLUDED,
        excluded_titles=EXCLUDED,
    )
    assert impact["rejected"] is not None


def test_below_floor_but_improving_is_allowed():
    impact = pattern_update_impact(
        old=None,
        new=["^Klassiker, Folge (\\d+):"],
        included_titles=INCLUDED,
        excluded_titles=EXCLUDED,
    )
    assert impact["rejected"] is None
