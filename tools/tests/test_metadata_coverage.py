"""The episode pattern is measured against the series' own albums.

Split children share an artist page with a whole author (Astrid
Lindgren: 140 albums). Measured against every title there, Madita's
correct "^Madita (\\d+)" covered 1%, the metadata check rejected it,
and after 10-15 requests the agent settled for no pattern at all
(2026-10-01). A series that ships albums is measured against those;
only a series that ships nothing yet is measured against the page.
"""

import pytest

from lauschi_catalog.catalog.curate_ops import (
    coverage_titles,
    metadata_problem,
    pattern_update_impact,
)
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig

PAGE = [
    "Madita 1. Hörspielklassiker",
    "Madita 2. Madita und Pims. Hörspielklassiker",
    *[f"Pippi Langstrumpf {i}" for i in range(1, 60)],
]


def _madita(*titles: str) -> CatalogEntry:
    albums = [{"id": f"m{i}", "title": t} for i, t in enumerate(titles)]
    return CatalogEntry(
        id="madita",
        title="Madita",
        split_from="astrid_lindgren_deutsch",
        providers={
            "spotify": ProviderConfig(
                artist_ids=["lindgren"],
                album_ids=[a["id"] for a in albums],
                albums=albums,
            )
        },
    )


def test_a_series_that_ships_albums_is_measured_against_them() -> None:
    entry = _madita("Madita 1. Hörspielklassiker", "Madita und Pims")
    assert coverage_titles(entry, PAGE) == [
        "Madita 1. Hörspielklassiker",
        "Madita und Pims",
    ]


def test_a_series_that_ships_nothing_yet_is_measured_against_the_page() -> None:
    assert coverage_titles(_madita(), PAGE) == PAGE
    assert coverage_titles(None, PAGE) == PAGE


def test_a_pattern_that_numbers_the_own_line_passes() -> None:
    titles = coverage_titles(
        _madita("Madita 1. Hörspielklassiker", "Madita 2. Madita und Pims"), PAGE
    )
    assert metadata_problem(r"^Madita (\d+)", titles, checks=1) is None


def test_a_pattern_missing_most_own_titles_is_sent_back() -> None:
    problem = metadata_problem(r"^Folge (\d+):", PAGE, checks=1)
    assert problem is not None and "Coverage only" in problem


def test_no_pattern_needs_no_coverage_check() -> None:
    """Named titles have nothing to test; demanding a check made agents
    run nonsense patterns like ^(\\d{100})$ to get past it."""
    assert metadata_problem(None, PAGE, checks=0) is None


def test_a_proposed_pattern_must_have_been_checked() -> None:
    problem = metadata_problem(r"^Madita (\d+)", PAGE, checks=0)
    assert problem is not None and "check_pattern_coverage" in problem


@pytest.mark.parametrize(("numbered", "accepted"), [(2, False), (4, True)])
def test_metadata_and_finalize_share_one_coverage_floor(
    numbered: int, accepted: bool
) -> None:
    """The metadata phase measures a pattern against what the series
    ships, finalize against this run's includes: the same line at two
    points of the run, held to the same floor."""
    titles = [f"Folge {i}" for i in range(numbered)] + [
        f"Special {i}" for i in range(10 - numbered)
    ]
    pattern = r"^Folge (\d+)"
    assert (metadata_problem(pattern, titles, checks=1) is None) is accepted
    impact = pattern_update_impact(r"^(?:Folge|Special) (\d+)", pattern, titles, [])
    assert (impact["rejected"] is None) is accepted
