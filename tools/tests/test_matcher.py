"""Tests for catalog.matcher episode-pattern utilities."""

from lauschi_catalog.catalog.matcher import (
    compute_pattern_coverage,
    extract_episode,
)

# ── extract_episode (existing API, smoke-level) ────────────────────────────


def test_extract_episode_returns_int_on_match():
    assert extract_episode(r"^Folge (\d+):", "Folge 47: Title") == 47


def test_extract_episode_returns_none_on_miss():
    assert extract_episode(r"^Folge (\d+):", "Special edition") is None


def test_extract_episode_tries_patterns_in_order():
    """Pattern list returns the first match."""
    patterns = [r"^Folge (\d+):", r"^(\d+)/"]
    assert extract_episode(patterns, "047/Title") == 47


# ── Over-escaped regex fix ────────────────────────────────────────────────


# Over-escaped patterns are no longer repaired here. They are refused
# where they enter (curate_ops._validate_episode_pattern on the agent's
# output, validate_ops.validate_l1 on the catalog), so extraction can use
# the pattern exactly as written. Silently repairing it is what let a
# broken lieselotte_filmhoerspiele pattern work in the pipeline while the
# app could not match it for months.


def test_extract_episode_does_not_repair_an_over_escaped_pattern():
    assert extract_episode("^Folge (\\\\d+):", "Folge 47: Title") is None


def test_compute_coverage_does_not_repair_an_over_escaped_pattern():
    titles = ["Folge 1: A", "Folge 2: B", "Special"]
    result = compute_pattern_coverage(titles, "^Folge (\\\\d+):")
    assert result["matched"] == 0
    assert result["total"] == 3


def test_compute_coverage_respects_max_samples():
    titles = [f"Special {i}" for i in range(30)] + ["Folge 1: A"]
    result = compute_pattern_coverage(titles, "^Folge (\\d+):", max_samples=15)
    assert result["matched"] == 1
    assert len(result["unmatched_regex_samples"]) == 15

    result_default = compute_pattern_coverage(titles, "^Folge (\\d+):")
    assert len(result_default["unmatched_regex_samples"]) == 5


# ── capture-group walking ──────────────────────────────────────────────────
#
# Reading group 1 only means a pattern whose match lands on a later
# alternative silently yields nothing. Verified to affect zero albums in the
# current catalog, so this closes a trap for the next multi-alternative
# pattern rather than fixing live breakage. It also adopts the one thing the
# deleted Dart implementation got right.


def test_extract_episode_reads_a_later_alternatives_group():
    pattern = r"(?:^Folge (\d+):)|(?:^(\d+)/)"
    assert extract_episode(pattern, "Folge 12: Der Superstar") == 12
    assert extract_episode(pattern, "012/Die Falle") == 12


def test_extract_episode_prefers_the_leftmost_group_that_matched():
    pattern = r"(?:^(\d+)/)|(?:Folge (\d+))"
    assert extract_episode(pattern, "007/Folge 99") == 7


def test_extract_episode_still_returns_none_when_no_group_has_digits():
    assert extract_episode(r"^(Folge) (\w+):", "Folge zwölf: x") is None
