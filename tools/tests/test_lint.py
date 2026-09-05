"""Tests for deterministic lint checks.

lint_curation is the guardrail: it catches structural invariants that
should hold for every Hörspiel series. These tests pin the behavior
with and without series_facts so we can trust the lint output.
"""

from lauschi_catalog.catalog.lint_ops import lint_curation


def _make_album(
    album_id: str,
    title: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
    release_date: str = "",
    confidence: str | None = None,
    notes: str | None = None,
) -> dict:
    album = {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": title,
        "exclude_reason": exclude_reason,
        "release_date": release_date,
    }
    if confidence is not None:
        album["confidence"] = confidence
    if notes is not None:
        album["notes"] = notes
    return album


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
                "known_gaps": [
                    {
                        "number": 2,
                        "reason": "legal dispute",
                        "curated_by": "curate",
                        "audited_by": "audit",
                    }
                ],
            },
        }
        assert lint_curation(curation) == []

    def test_known_gap_range_suppresses_all_episodes(self):
        """A single range gap covers all episodes in the range."""
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a5", "Ep 5", episode_num=5),
            ],
            "series_facts": {
                "known_gaps": [
                    {
                        "number": 2,
                        "range_end": 4,
                        "reason": "not produced",
                        "curated_by": "curate",
                        "audited_by": "audit",
                    }
                ],
            },
        }
        assert lint_curation(curation) == []

    def test_known_gap_range_partial_still_flags_remainder(self):
        """A range that doesn't cover all gaps leaves the rest flagged."""
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a6", "Ep 6", episode_num=6),
            ],
            "series_facts": {
                "known_gaps": [
                    {
                        "number": 2,
                        "range_end": 4,
                        "reason": "not produced",
                        "curated_by": "curate",
                        "audited_by": "audit",
                    }
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("[5]" in i for i in issues)

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
                    {
                        "label": "modern",
                        "release_date_range": "2019-2022",
                        "curated_by": "curate",
                    },
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
        assert any(
            "Episode 3 included but 2 excluded without reason" in i for i in issues
        )

    def test_n_without_n_minus_1_excluded_with_reason(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album(
                    "a2",
                    "Ep 2",
                    episode_num=2,
                    include=False,
                    exclude_reason="duplicate",
                ),
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
                _make_album(
                    "a2", "Ep 1", provider="apple_music", episode_num=1, include=False
                ),
            ],
        }
        issues = lint_curation(curation)
        assert any("excluded without reason on apple_music" in i for i in issues)

    def test_episode_excluded_with_reason_ok(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", provider="spotify", episode_num=1),
                _make_album(
                    "a2",
                    "Ep 1",
                    provider="apple_music",
                    episode_num=1,
                    include=False,
                    exclude_reason="duplicate",
                ),
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
                        "curated_by": "curate",
                        "audited_by": None,
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Unaudited era_boundary 'modern'" in i for i in issues)

    def test_unconfirmed_known_gap_flagged(self):
        curation = {
            "albums": [],
            "series_facts": {
                "known_gaps": [
                    {
                        "number": 7,
                        "reason": "legal dispute",
                        "curated_by": "curate",
                        "audited_by": None,
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Unaudited known_gap ep 7" in i for i in issues)

    def test_unconfirmed_known_gap_range_shows_range(self):
        curation = {
            "albums": [],
            "series_facts": {
                "known_gaps": [
                    {
                        "number": 51,
                        "range_end": 200,
                        "reason": "not produced",
                        "curated_by": "curate",
                        "audited_by": None,
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("Unaudited known_gap ep 51-200" in i for i in issues)
        assert len([i for i in issues if "known_gap" in i]) == 1

    def test_confirmed_facts_not_flagged(self):
        curation = {
            "albums": [],
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "modern",
                        "release_date_range": "2020-2022",
                        "curated_by": "curate",
                        "audited_by": "audit",
                    },
                ],
            },
        }
        assert lint_curation(curation) == []


class TestLintLowConfidence:
    def test_no_low_confidence_no_issue(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1, confidence="high"),
                _make_album("a2", "Ep 2", episode_num=2, confidence="high"),
            ],
        }
        assert lint_curation(curation) == []

    def test_few_low_confidence_no_issue(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1, confidence="high"),
                _make_album(
                    "a2", "Ep 2", episode_num=2, confidence="medium", notes="unsure"
                ),
            ],
        }
        assert lint_curation(curation) == []

    def test_many_low_confidence_fires(self):
        curation = {
            "albums": [
                _make_album(
                    f"a{i}",
                    f"Ep {i}",
                    episode_num=i,
                    confidence="medium",
                    notes="unsure",
                )
                for i in range(1, 7)
            ],
        }
        issues = lint_curation(curation)
        assert any("low_confidence_cluster" in i for i in issues)
        assert any("6 decisions are MEDIUM or LOW" in i for i in issues)

    def test_percentage_threshold_fires_on_small_series(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1, confidence="high"),
                _make_album(
                    "a2", "Ep 2", episode_num=2, confidence="medium", notes="unsure"
                ),
                _make_album(
                    "a3", "Ep 3", episode_num=3, confidence="medium", notes="unsure"
                ),
                _make_album(
                    "a4", "Ep 4", episode_num=4, confidence="medium", notes="unsure"
                ),
            ],
        }
        issues = lint_curation(curation)
        # 4 albums, threshold = max(5, 0) = 5, but wait: 4//10 = 0, max(5, 0) = 5
        # 3 MEDIUM < 5, so no issue
        assert not any("low_confidence_cluster" in i for i in issues)

    def test_percentage_threshold_fires_on_medium_series(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1, confidence="high"),
                *[
                    _make_album(
                        f"a{i}",
                        f"Ep {i}",
                        episode_num=i,
                        confidence="medium",
                        notes="unsure",
                    )
                    for i in range(2, 13)
                ],
            ],
        }
        issues = lint_curation(curation)
        # 12 albums, 11 MEDIUM, threshold = max(5, 1) = 5
        assert any("low_confidence_cluster" in i for i in issues)

    def test_legacy_albums_without_confidence_treated_as_high(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                _make_album("a2", "Ep 2", episode_num=2),
            ],
        }
        assert lint_curation(curation) == []


class TestEpisodeNumSanity:
    def test_episode_zero_is_valid(self):
        """Folge 00 is a real pilot episode (e.g. Die Originale)."""
        curation = {
            "albums": [
                _make_album("a0", "Folge 00: Goldrausch", episode_num=0),
                _make_album("a1", "Folge 01: Weltreise", episode_num=1),
            ],
        }
        assert lint_curation(curation) == []

    def test_negative_episode_num_flagged(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep -1", episode_num=-1),
            ],
        }
        issues = lint_curation(curation)
        assert any("episode_num_sanity" in i for i in issues)

    def test_episode_1000_flagged(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 2023", episode_num=2023),
            ],
        }
        issues = lint_curation(curation)
        assert any("episode_num_sanity" in i for i in issues)

    def test_normal_episode_num_ok(self):
        curation = {
            "albums": [
                _make_album("a1", "Folge 42: Something", episode_num=42),
            ],
        }
        assert lint_curation(curation) == []


class TestNoAutoIncludedRule:
    """Auto-include was removed; Rule 8 should no longer fire."""

    def test_auto_included_note_is_not_flagged(self):
        curation = {
            "albums": [
                _make_album("a1", "Ep 1", episode_num=1),
                {
                    **_make_album("a2", "Mystery Album"),
                    "notes": "auto-included: agent omitted this album from its output",
                },
            ],
        }
        issues = lint_curation(curation)
        assert not any("auto_included" in i for i in issues)


# ── Rule 12: split title clusters ─────────────────────────────────────


def _kartoffelbrei(n: int, *, include: bool, reason: str | None = None) -> dict:
    return _make_album(
        f"kk{n}",
        f"Kampf um Kartoffelbrei (Special) - Teil {n}: Geschichte {n}",
        include=include,
        exclude_reason=reason,
    )


class TestSplitClusterRule:
    """A title cluster is one line. Judging part of it fine and the rest
    wrong content is the inconsistency a whole-list read found on Bibi
    Blocksberg (parts 1-4 in, 5-11 out as sub_series) and no rule caught."""

    def test_content_reason_split_fires_with_counts(self):
        albums = [_kartoffelbrei(n, include=True) for n in (1, 2, 3, 4)] + [
            _kartoffelbrei(n, include=False, reason="sub_series_bleed")
            for n in (5, 6, 7)
        ]
        issues = lint_curation({"albums": albums})
        hits = [i for i in issues if i.startswith("[split_cluster]")]
        assert len(hits) == 1
        assert "4 included, 3 excluded as sub_series_bleed" in hits[0]

    def test_duplicate_split_is_deliberate_and_silent(self):
        """A main line with a duplicate excluded beside its twin is a
        correct split, not a contradiction. 'folge n' must not fire."""
        albums = [
            _make_album("f1", "Folge 1: A", episode_num=1),
            _make_album("f2", "Folge 2: B", episode_num=2),
            _make_album(
                "f2b",
                "Folge 2: B",
                episode_num=2,
                include=False,
                exclude_reason="duplicate",
            ),
            _make_album(
                "f3",
                "Folge 3: C",
                episode_num=3,
                include=False,
                exclude_reason="format_variant",
            ),
        ]
        issues = lint_curation({"albums": albums})
        assert not [i for i in issues if i.startswith("[split_cluster]")]

    def test_case_and_suffix_variants_of_a_reason_count(self):
        """Reasons are written by several models and by hand: 'Wrong content
        type: ...' and 'sub_series_bleed - lives in x' must classify the
        same as their canonical keys, or the split goes unseen."""
        albums = [
            _kartoffelbrei(1, include=True),
            _kartoffelbrei(
                2, include=False, reason="Wrong content type: audiobook chapters"
            ),
            _kartoffelbrei(
                3, include=False, reason="sub_series_bleed - lives in other_series"
            ),
        ]
        issues = lint_curation({"albums": albums})
        hits = [i for i in issues if i.startswith("[split_cluster]")]
        assert len(hits) == 1
        assert "excluded as sub_series_bleed, wrong_content_type" in hits[0]

    def test_singleton_cluster_never_fires(self):
        albums = [
            _make_album(
                "x", "Ein Einzeltitel", include=False, exclude_reason="compilation"
            )
        ]
        assert not [
            i for i in lint_curation({"albums": albums}) if "split_cluster" in i
        ]


# ── Rule 11: cross-provider title counterparts (normalized reasons) ───


class TestTitleCounterpartRule:
    """Rule 11 compared the raw exclude_reason with ==, so a reason with a
    free-text suffix or different casing never matched and the
    contradiction went unreported: on the live catalog it found 7 of ~71.
    """

    def _pair(self, reason: str) -> list[dict]:
        return [
            _make_album("s1", "Seeräuber Wackelzahn", provider="spotify"),
            _make_album(
                "a1",
                "Seeräuber Wackelzahn",
                provider="apple_music",
                include=False,
                exclude_reason=reason,
            ),
        ]

    def test_canonical_reason_fires(self):
        issues = lint_curation({"albums": self._pair("compilation")})
        assert any(i.startswith("[title_counterpart]") for i in issues)

    def test_suffixed_reason_fires(self):
        issues = lint_curation(
            {"albums": self._pair("sub_series_bleed - bonus track from ep 50")}
        )
        assert any(i.startswith("[title_counterpart]") for i in issues)

    def test_capitalized_reason_fires(self):
        issues = lint_curation({"albums": self._pair("Wrong content type: audiobook")})
        assert any(i.startswith("[title_counterpart]") for i in issues)

    def test_redundancy_reason_stays_silent(self):
        issues = lint_curation({"albums": self._pair("duplicate")})
        assert not any(i.startswith("[title_counterpart]") for i in issues)


class TestFragmentIncluded:
    """An included title that extends an excluded sibling's title on
    the same provider is fragment-shaped (Die Playmos, Apple Music:
    "... - Episode 1" shipped while the full album sat excluded). The
    correct state includes the shorter title, so direction matters."""

    def test_included_fragment_of_an_excluded_sibling_is_flagged(self):
        albums = [
            _make_album(
                "am_full",
                "Folge 100: Der magische Ring",
                provider="apple_music",
                include=False,
                exclude_reason="unspecified",
            ),
            _make_album(
                "am_frag",
                "Folge 100: Der magische Ring - Episode 1",
                provider="apple_music",
                include=True,
                episode_num=100,
            ),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert any("[fragment_included]" in i for i in issues)

    def test_full_album_included_with_fragments_excluded_is_clean(self):
        albums = [
            _make_album(
                "sp_full",
                "Folge 100: Der magische Ring",
                provider="spotify",
                include=True,
                episode_num=100,
            ),
            _make_album(
                "sp_part",
                "Folge 100: Der magische Ring - Episode 1",
                provider="spotify",
                include=False,
                exclude_reason="partial_release",
            ),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert not any("[fragment_included]" in i for i in issues)


class TestDataIntegrityRules:
    def test_duplicate_provider_album_id_is_flagged(self):
        albums = [
            _make_album("dup", "Folge 1: A", provider="spotify", episode_num=1),
            _make_album("dup", "Folge 1: A", provider="spotify", episode_num=1),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert any("[duplicate_album_id]" in i and "spotify:dup" in i for i in issues)

    def test_same_id_on_two_providers_is_not_a_duplicate(self):
        albums = [
            _make_album("x", "Folge 1: A", provider="spotify", episode_num=1),
            _make_album("x", "Folge 1: A", provider="apple_music", episode_num=1),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert not any("[duplicate_album_id]" in i for i in issues)

    def test_unknown_exclude_reason_is_flagged(self):
        albums = [
            _make_album("a", "Best Of", include=False, exclude_reason="made_up_reason"),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert any(
            "[unknown_exclude_reason]" in i and "made_up_reason" in i for i in issues
        )

    def test_a_known_reason_is_clean(self):
        albums = [
            _make_album("a", "Best Of", include=False, exclude_reason="compilation"),
        ]
        issues = lint_curation({"id": "s", "albums": albums})
        assert not any("[unknown_exclude_reason]" in i for i in issues)

    def test_known_gap_contradicted_by_an_included_episode(self):
        albums = [_make_album("a", "Folge 5: Here", episode_num=5)]
        curation = {
            "id": "s",
            "albums": albums,
            "series_facts": {
                "known_gaps": [
                    {"number": 5, "reason": "never released", "curated_by": "curate"}
                ]
            },
        }
        issues = lint_curation(curation)
        assert any("[gap_contradicted]" in i and "5" in i for i in issues)

    def test_a_real_gap_is_clean(self):
        albums = [_make_album("a", "Folge 4: Here", episode_num=4)]
        curation = {
            "id": "s",
            "albums": albums,
            "series_facts": {
                "known_gaps": [
                    {"number": 5, "reason": "never released", "curated_by": "curate"}
                ]
            },
        }
        issues = lint_curation(curation)
        assert not any("[gap_contradicted]" in i for i in issues)

    def test_gap_not_flagged_when_numbers_repeat_across_eras(self):
        # Die Schlümpfe: a gap at classic-era episode 1 coexists with an
        # included modern-era episode 1, so the flat number is ambiguous.
        albums = [_make_album("a", "Folge 1: Modern", episode_num=1)]
        curation = {
            "id": "s",
            "albums": albums,
            "series_facts": {
                "known_gaps": [
                    {"number": 1, "reason": "classic missing", "curated_by": "curate"}
                ],
                "era_boundaries": [
                    {
                        "label": "classic",
                        "release_date_range": "1980-1990",
                        "curated_by": "curate",
                    },
                    {
                        "label": "modern",
                        "release_date_range": "2020-",
                        "curated_by": "curate",
                    },
                ],
            },
        }
        issues = lint_curation(curation)
        assert not any("[gap_contradicted]" in i for i in issues)


class TestUnspecifiedCount:
    """574 albums are excluded with no named reason. On a Hörspiel series
    that is a hole in the policy, not a decision, so lint counts them."""

    def test_unspecified_excludes_on_a_hoerspiel_series_are_counted(self):
        albums = [
            _make_album("a", "Irgendwas", include=False, exclude_reason="unspecified"),
            _make_album("b", "Noch was", include=False, exclude_reason="unspecified"),
            _make_album("c", "Best Of", include=False, exclude_reason="compilation"),
        ]
        issues = lint_curation(
            {"id": "s", "content_type": "hoerspiel", "albums": albums}
        )
        hits = [i for i in issues if i.startswith("[unspecified_count]")]
        assert len(hits) == 1
        assert "2" in hits[0]

    def test_zero_unspecified_is_silent(self):
        albums = [
            _make_album("c", "Best Of", include=False, exclude_reason="compilation")
        ]
        issues = lint_curation(
            {"id": "s", "content_type": "hoerspiel", "albums": albums}
        )
        assert not any(i.startswith("[unspecified_count]") for i in issues)

    def test_music_series_are_left_to_their_own_scope_rule(self):
        albums = [
            _make_album(
                "a", "Feat. Single", include=False, exclude_reason="unspecified"
            )
        ]
        issues = lint_curation({"id": "s", "content_type": "music", "albums": albums})
        assert not any(i.startswith("[unspecified_count]") for i in issues)
