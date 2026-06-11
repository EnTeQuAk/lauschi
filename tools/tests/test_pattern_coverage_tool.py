"""Pin that pattern-coverage errors reach the model.

When compute_pattern_coverage returns an error (invalid regex, missing
capture group), the report must carry that error in ``message``.
Dropping it returns all-zeros with no explanation, which reads to the
model like "the pattern matched nothing", sending it down wrong paths
(one model concluded list patterns were unsupported and merged its
clean per-era regexes into one unanchored blob).
"""

from __future__ import annotations

from lauschi_catalog.catalog.curate_ops import _pattern_coverage_report

TITLES = [
    "Folge 1: Der Anfang",
    "Folge 2: Die Reise",
    "Klassiker, Folge 3: Der Schatz",
    "16/Die fantastischen Vier (CGI)",
]


def test_invalid_regex_error_lands_in_message():
    report = _pattern_coverage_report(TITLES, "^Folge ((\\d+:")
    assert "invalid regex" in report.message
    assert report.total == 0


def test_missing_capture_group_error_lands_in_message():
    report = _pattern_coverage_report(TITLES, "^Folge \\d+:")
    assert "capture group" in report.message


def test_list_of_patterns_first_match_wins():
    """A list of era patterns is a supported input, not an error."""
    report = _pattern_coverage_report(
        TITLES,
        ["^Folge (\\d+):", "^Klassiker, Folge (\\d+):", "^(\\d+)/"],
    )
    assert report.message == ""
    assert report.matched == 4
    assert report.coverage == 1.0


def test_one_invalid_pattern_in_list_reports_which():
    report = _pattern_coverage_report(TITLES, ["^Folge (\\d+):", "(("])
    assert "((" in report.message
