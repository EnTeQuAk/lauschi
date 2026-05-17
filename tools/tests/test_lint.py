"""Tests for deterministic lint checks.

lint_curation is the guardrail: it catches structural invariants that
should hold for every Hörspiel series. These tests pin the behavior
with and without series_facts so we can trust the lint output.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.commands.lint import lint_curation


def _make_album(
    album_id: str,
    title: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
    release_date: str = "",
) -> dict:
    return {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": title,
        "exclude_reason": exclude_reason,
        "release_date": release_date,
    }


class TestLintGapDetection:
    def test_no_gap(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 2", episode_num=2),
                _make_album("a3", "Ep 3", episode_num=3),
            ],
        }
        assert lint_curation(curation) == []

    def test_unknown_gap(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a3", "Ep 3", episode_num=3),
            ],
        }
        issues = lint_curation(curation)
        assert any("Unexpected gaps at episodes: [2]" in i for i in issues)

    def test_known_gap_skipped(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a3", "Ep 3", episode_num=3),
            ],
            "series_facts": {
                "known_gaps": [{"number": 2, "reason": "legal dispute", "discovered_by": "curate"}],
            },
        }
        assert lint_curation(curation) == []

    def test_multiple_unknown_gaps(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a5", "Ep 5", episode_num=5),
            ],
        }
        issues = lint_curation(curation)
        assert any("Unexpected gaps at episodes: [2, 3, 4]" in i for i in issues)


class TestLintDuplicateDetection:
    def test_no_duplicates(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 2", episode_num=2),
            ],
        }
        assert lint_curation(curation) == []

    def test_duplicate_episode_same_provider(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 1 remaster", episode_num=1),
            ],
        }
        issues = lint_curation(curation)
        assert any("Duplicate episode numbers" in i for i in issues)

    def test_duplicate_ok_across_providers(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                _make_album("a2", "Ep 1", provider="apple_music", episode_num=1),
            ],
        }
        # Duplicates are checked per-provider, so cross-provider same
        # episode number is fine
        assert lint_curation(curation) == []

    def test_duplicate_within_era(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1, release_date="2020-01-01"),
                _make_album("a2", "Ep 1 alt", episode_num=1, release_date="2020-02-01"),
            ],
            "series_facts": {
                "era_boundaries": [
                    {"label": "modern", "release_date_range": "2019-2022", "discovered_by": "curate"},
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Duplicate episode numbers within era 'modern'" in i for i in issues)


class TestLintEpisodeNWithoutNMinus1:
    def test_n_without_n_minus_1_excluded_no_reason(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 2", episode_num=2, include=False),
                _make_album("a3", "Ep 3", episode_num=3),
            ],
        }
        issues = lint_curation(curation)
        assert any("Episode 3 included but 2 excluded without reason" in i for i in issues)

    def test_n_without_n_minus_1_excluded_with_reason(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 2", episode_num=2, include=False, exclude_reason="duplicate"),
                _make_album("a3", "Ep 3", episode_num=3),
            ],
        }
        # Episode 2 is excluded with reason, so no "without reason" flag.
        # But episode 2 is still a gap between 1 and 3.
        issues = lint_curation(curation)
        assert not any("excluded without reason" in i for i in issues)
        assert any("Unexpected gaps at episodes: [2]" in i for i in issues)

    def test_episode_1_no_previous(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
            ],
        }
        assert lint_curation(curation) == []


class TestLintPatternCoverage:
    def test_coverage_above_threshold(self):
        curation = {
            "episode_pattern": r"^Folge (\d+):",
            "albums": [
                _make_album("a1", "Folge 1: A", episode_num=1),
                _make_album("a2", "Folge 2: B", episode_num=2),
                _make_album("a3", "Folge 3: C", episode_num=3),
            ],
        }
        assert lint_curation(curation) == []

    def test_coverage_below_threshold(self):
        curation = {
            "episode_pattern": r"^Folge (\d+):",
            "albums": [
                _make_album("a1", "Folge 1: A", episode_num=1),
                _make_album("a2", "Named Episode", episode_num=None),
                _make_album("a3", "Another Named", episode_num=None),
                _make_album("a4", "Yet Another", episode_num=None),
            ],
        }
        issues = lint_curation(curation)
        assert any("Pattern coverage 25%" in i for i in issues)


class TestLintCrossProviderAsymmetry:
    def test_symmetric_providers_clean(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                _make_album("a2", "Ep 1", provider="apple_music", episode_num=1),
            ],
        }
        assert lint_curation(curation) == []

    def test_episode_missing_from_provider_not_excluded(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                # apple_music has no albums at all for this series
            ],
        }
        issues = lint_curation(curation)
        # Cross-provider asymmetry only flags when the missing provider
        # has albums in the curation but is missing this specific episode.
        # If a provider has zero albums, that's a discovery issue, not
        # an asymmetry.
        assert not any("not even excluded" in i for i in issues)

    def test_episode_excluded_without_reason(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                _make_album("a2", "Ep 1", provider="apple_music", episode_num=1, include=False),
            ],
        }
        issues = lint_curation(curation)
        assert any("excluded without reason on apple_music" in i for i in issues)

    def test_episode_excluded_with_reason_ok(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                _make_album("a2", "Ep 1", provider="apple_music", episode_num=1, include=False, exclude_reason="duplicate"),
            ],
        }
        assert lint_curation(curation) == []


class TestLintUnconfirmedFacts:
    def test_unconfirmed_era_boundary_flagged(self):
        curation = {
            "albums": [],
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "modern",
                        "release_date_range": "2020-2022",
                        "discovered_by": "curate",
                        "verify_status": "disagreed",
                        "verify_reasoning": "no albums in this range",
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Unconfirmed era_boundary 'modern'" in i for i in issues)

    def test_unconfirmed_known_gap_flagged(self):
        curation = {
            "albums": [],
            "series_facts": {
                "known_gaps": [
                    {
                        "number": 7,
                        "reason": "legal dispute",
                        "discovered_by": "curate",
                        "verify_status": "disagreed",
                        "verify_reasoning": "episode exists on provider",
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Unconfirmed known_gap ep 7" in i for i in issues)

    def test_confirmed_facts_not_flagged(self):
        curation = {
            "albums": [],
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "modern",
                        "release_date_range": "2020-2022",
                        "discovered_by": "curate",
                        "verify_status": "agreed",
                    },
                ],
            },
        }
        assert lint_curation(curation) == []
