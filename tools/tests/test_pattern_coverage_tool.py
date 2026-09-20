"""Pin pattern-coverage tool behavior: error reporting, bucket
separation, alternation semantics, and sample distribution.

When compute_pattern_coverage returns an error (invalid regex, missing
capture group), the report must carry that error in ``message``.
Dropping it returns all-zeros with no explanation, which reads to the
model like "the pattern matched nothing", sending it down wrong paths
(one model concluded list patterns were unsupported and merged its
clean per-era regexes into one unanchored blob).
"""

from lauschi_catalog.catalog.curate_ops import _pattern_coverage_report
from lauschi_catalog.catalog.matcher import compute_pattern_coverage

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


# ── compute_pattern_coverage bucket separation ───────────────────────────


def test_pattern_coverage_separates_no_match_from_non_numeric():
    """The motivating SimsalaGrimm bug. Episodes are named
    ('Aladin und die Wunderlampe (...)'), never numbered. With
    ``(.*)`` the regex matches every title but the capture is the
    whole title, distinct from 'regex didn't match'."""
    titles = [
        "Aladin und die Wunderlampe (Das Original-Hörspiel zur TV Serie)",
        "Aschenputtel (Das Original-Hörspiel zur TV Serie)",
    ]
    result = compute_pattern_coverage(titles, "(.*)")
    assert result["matched"] == 0
    assert result["coverage"] == 0.0
    assert len(result["non_numeric_capture_samples"]) == 2
    assert result["unmatched_regex_samples"] == []
    captured = result["non_numeric_capture_samples"][0]["captured"]
    assert "Aladin" in captured


def test_pattern_coverage_alternation_falls_through_non_numeric():
    """List of patterns: if one captures non-numeric but a later
    one captures a digit on the same title, the title counts as
    matched. Pins the inner-loop early-exit semantics."""
    titles = ["Folge 5: Boom"]
    result = compute_pattern_coverage(
        titles,
        [r"^(.+):", r"^Folge (\d+):"],
    )
    assert result["matched"] == 1
    assert result["non_numeric_capture_samples"] == []


def test_pattern_coverage_samples_spread_across_list():
    """Unmatched samples should be spread evenly, not head-biased."""
    titles = [f"Title {i}" for i in range(20)]
    result = compute_pattern_coverage(titles, r"^Folge (\d+):")
    assert result["matched"] == 0
    samples = result["unmatched_regex_samples"]
    assert len(samples) == 5
    assert samples[0] == "Title 0"
    assert samples[-1] == "Title 16"
    assert samples != titles[:5]
