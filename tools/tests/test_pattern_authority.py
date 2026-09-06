"""The episode_pattern in series.yaml is a fact: a run starts from it,
and a revision may not lose numbers.

The metadata agent re-derived Wieso? Weshalb? Warum?'s pattern with a
closing parenthesis the provider truncates away (2026-09-06), so the
fixed pattern in series.yaml was overwritten on apply and four
title-borne numbers went missing again.
"""

from lauschi_catalog.catalog.curate_ops import _pattern_for_run, pattern_update_impact

INCLUDED = [
    "Alles über Laster (Wieso? Weshalb? Warum? Folge 38",
    "Ozeane (Wieso? Weshalb? Warum? Folge 40)",
]
FIXED = r"\(Wieso\? Weshalb\? Warum\? Folge\s*(\d+)"
STRICT = r"\(Wieso\? Weshalb\? Warum\? Folge\s*(\d+)\)"


def test_the_entry_pattern_wins_over_the_proposal():
    assert _pattern_for_run(FIXED, STRICT) == FIXED


def test_without_an_entry_pattern_the_proposal_is_used():
    assert _pattern_for_run(None, STRICT) == STRICT
    assert _pattern_for_run("", None) is None


def test_a_revision_of_a_catalog_pattern_may_not_lose_numbers():
    impact = pattern_update_impact(
        FIXED, STRICT, included_titles=INCLUDED, excluded_titles=[], frozen=True
    )
    assert impact["rejected"] and "series.yaml" in impact["rejected"]


def test_a_revision_of_a_proposed_pattern_may_denoise():
    impact = pattern_update_impact(
        FIXED, STRICT, included_titles=INCLUDED, excluded_titles=[]
    )
    assert impact["rejected"] is None
