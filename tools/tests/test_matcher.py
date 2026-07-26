"""Tests for catalog.matcher episode-pattern utilities."""

from __future__ import annotations

from lauschi_catalog.catalog.matcher import (
    apply_episode_pattern,
    compute_pattern_coverage,
    extract_episode,
    preview_episode_pattern,
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


# ── preview_episode_pattern ────────────────────────────────────────────────


def test_preview_returns_zero_for_empty_albums():
    assert preview_episode_pattern([], r"^Folge (\d+):") == 0


def test_preview_counts_albums_that_would_change():
    albums = [
        {"title": "Folge 1: A", "episode_num": None},
        {"title": "Folge 2: B", "episode_num": 99},  # wrong number
        {"title": "Folge 3: C", "episode_num": 3},  # already correct
    ]
    assert preview_episode_pattern(albums, r"^Folge (\d+):") == 2


def test_preview_ignores_non_matching_titles():
    albums = [
        {"title": "Special: Pilot", "episode_num": None},
    ]
    assert preview_episode_pattern(albums, r"^Folge (\d+):") == 0


def test_preview_does_not_mutate_input():
    albums = [{"title": "Folge 1: A", "episode_num": None}]
    preview_episode_pattern(albums, r"^Folge (\d+):")
    assert albums[0]["episode_num"] is None


# ── apply_episode_pattern ──────────────────────────────────────────────────


def test_apply_returns_new_list_with_updated_episode_nums():
    albums = [
        {"title": "Folge 1: A", "episode_num": None},
        {"title": "Folge 2: B", "episode_num": 99},
    ]
    result = apply_episode_pattern(albums, r"^Folge (\d+):")
    assert result == [
        {"title": "Folge 1: A", "episode_num": 1},
        {"title": "Folge 2: B", "episode_num": 2},
    ]


def test_apply_does_not_mutate_input_albums():
    albums = [{"title": "Folge 1: A", "episode_num": None}]
    apply_episode_pattern(albums, r"^Folge (\d+):")
    assert albums[0]["episode_num"] is None


def test_apply_preserves_other_album_fields():
    albums = [
        {
            "title": "Folge 1: A",
            "episode_num": None,
            "include": True,
            "provider": "spotify",
        },
    ]
    result = apply_episode_pattern(albums, r"^Folge (\d+):")
    assert result[0]["include"] is True
    assert result[0]["provider"] == "spotify"
    assert result[0]["episode_num"] == 1


def test_apply_keeps_existing_episode_num_when_pattern_misses():
    """A non-matching title doesn't lose its previously-extracted number."""
    albums = [
        {"title": "Special: Pilot", "episode_num": 99},
    ]
    result = apply_episode_pattern(albums, r"^Folge (\d+):")
    assert result[0]["episode_num"] == 99


def test_apply_handles_pattern_list():
    albums = [
        {"title": "047/Title", "episode_num": None},
        {"title": "Folge 50: T", "episode_num": None},
    ]
    result = apply_episode_pattern(albums, [r"^Folge (\d+):", r"^(\d+)/"])
    assert result[0]["episode_num"] == 47
    assert result[1]["episode_num"] == 50


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
