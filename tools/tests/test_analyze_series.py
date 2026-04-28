"""Characterization tests for catalog.analysis.

These tests pin the current behavior of the structural analysis used by the
review agent's prompt. Any future change to analyze_series must keep these
green or update them deliberately.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.catalog.analysis import analyze_series, effective_albums

from .conftest import make_album, make_curation


# ── effective_albums ───────────────────────────────────────────────────────


def test_effective_albums_empty():
    assert effective_albums(make_curation(albums=[])) == []


def test_effective_albums_drops_excluded():
    curation = make_curation(albums=[
        make_album("a", "Folge 1: A", include=True),
        make_album("b", "Folge 2: B", include=False, exclude_reason="box set"),
    ])
    result = effective_albums(curation)
    assert [a["album_id"] for a in result] == ["a"]


def test_effective_albums_respects_review_overrides():
    curation = make_curation(
        albums=[
            make_album("a", "Folge 1: A", include=True),
            make_album("b", "Folge 2: B", include=True),
        ],
        review={
            "overrides": [
                {"album_id": "b", "action": "exclude", "reason": "duplicate"},
            ],
        },
    )
    result = effective_albums(curation)
    assert [a["album_id"] for a in result] == ["a"]


def test_effective_albums_ignores_include_overrides():
    """Override action='include' is not used to resurrect excluded albums."""
    curation = make_curation(
        albums=[
            make_album("a", "Folge 1: A", include=False),
        ],
        review={
            "overrides": [
                {"album_id": "a", "action": "include", "reason": "actually fine"},
            ],
        },
    )
    assert effective_albums(curation) == []


# ── analyze_series basic shape ─────────────────────────────────────────────


def test_analyze_empty_curation():
    result = analyze_series(make_curation(albums=[]))
    assert result == {
        "total": 0,
        "with_episode_num": 0,
        "episode_range": "none",
        "gaps": [],
        "providers": {},
        "common_words": [],
        "duplicates_within_provider": [],
        "title_clusters": [],
        "outliers": [],
        "outlier_count": 0,
        "cross_provider_coverage": {
            "by_provider": {},
            "missing_per_provider": {},
            "on_all_providers": 0,
        },
        "pattern_coverage": {"percentage": 0.0, "missing": 0},
    }


def test_analyze_returns_expected_keys():
    curation = make_curation(albums=[
        make_album("a", "Folge 1: A", episode_num=1),
    ])
    assert set(analyze_series(curation)) == {
        "total", "with_episode_num", "episode_range",
        "gaps", "providers", "common_words",
        "duplicates_within_provider", "title_clusters",
        "outliers", "outlier_count",
        "cross_provider_coverage", "pattern_coverage",
    }


# ── episode_range and gaps ─────────────────────────────────────────────────


def test_analyze_sequential_episodes_no_gaps():
    albums = [make_album(f"id{n}", f"Folge {n}: T", episode_num=n) for n in range(1, 6)]
    result = analyze_series(make_curation(albums=albums))
    assert result["episode_range"] == "1-5"
    assert result["gaps"] == []
    assert result["with_episode_num"] == 5


def test_analyze_finds_simple_gaps():
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
        make_album("c", "Folge 5: C", episode_num=5),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["episode_range"] == "1-5"
    assert result["gaps"] == [3, 4]


def test_analyze_caps_gaps_at_20():
    """Long gap runs are truncated to the first 20 missing numbers."""
    albums = [
        make_album("low", "Folge 1: low", episode_num=1),
        make_album("high", "Folge 100: high", episode_num=100),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert len(result["gaps"]) == 20
    assert result["gaps"] == list(range(2, 22))


def test_analyze_no_episode_nums_means_no_range():
    albums = [
        make_album("a", "Special: Pilot"),
        make_album("b", "Special: Christmas"),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["episode_range"] == "none"
    assert result["gaps"] == []
    assert result["with_episode_num"] == 0


def test_analyze_episode_num_zero_treated_as_missing():
    """Current behavior: episode_num=0 is filtered out by truthiness check.

    This is a quirk worth preserving deliberately. Episode numbering for
    Hörspiele starts at 1 in practice, so 0 is not a real value.
    """
    albums = [
        make_album("a", "Pilot", episode_num=0),
        make_album("b", "Folge 1: A", episode_num=1),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["with_episode_num"] == 1
    assert result["episode_range"] == "1-1"


# ── providers ──────────────────────────────────────────────────────────────


def test_analyze_counts_providers():
    albums = [
        make_album("a", "Folge 1: A", provider="spotify", episode_num=1),
        make_album("b", "Folge 1: A", provider="apple_music", episode_num=1),
        make_album("c", "Folge 2: B", provider="spotify", episode_num=2),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["providers"] == {"spotify": 2, "apple_music": 1}


def test_analyze_defaults_missing_provider_to_spotify():
    """Albums without a provider key default to spotify (legacy data shape)."""
    albums = [
        {"album_id": "a", "include": True, "episode_num": 1, "title": "Folge 1: A"},
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["providers"] == {"spotify": 1}


# ── common_words ───────────────────────────────────────────────────────────


def test_analyze_common_words_strips_noise():
    """Folge/Teil prefixes, digits, and parenthetical content are stripped."""
    albums = [
        make_album("a", "Folge 1: Mystery (Hörspiel)", episode_num=1),
        make_album("b", "Folge 2: Mystery Tour", episode_num=2),
        make_album("c", "Teil 3 Mystery Adventure", episode_num=3),
    ]
    result = analyze_series(make_curation(albums=albums))
    words = dict(result["common_words"])
    assert "mystery" in words
    assert "folge" not in words
    assert "teil" not in words
    assert "hörspiel" not in words


def test_analyze_common_words_drops_short_tokens():
    """Words of 3 chars or fewer are dropped."""
    albums = [
        make_album("a", "Folge 1: A B C Adventure", episode_num=1),
        make_album("b", "Folge 2: A B C Adventure", episode_num=2),
    ]
    result = analyze_series(make_curation(albums=albums))
    words = dict(result["common_words"])
    assert "adventure" in words
    assert "a" not in words
    assert "b" not in words


def test_analyze_common_words_limited_to_ten():
    titles = [f"Folge {n}: word{n}a word{n}b word{n}c" for n in range(1, 16)]
    albums = [
        make_album(f"id{n}", t, episode_num=n + 1)
        for n, t in enumerate(titles)
    ]
    result = analyze_series(make_curation(albums=albums))
    assert len(result["common_words"]) <= 10


# ── duplicates_within_provider ─────────────────────────────────────────────


def test_analyze_no_duplicates_means_empty_list():
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["duplicates_within_provider"] == []


def test_analyze_finds_same_provider_duplicate_episode_nums():
    albums = [
        make_album("a", "Folge 1: A", provider="spotify", episode_num=1),
        make_album("a2", "Folge 1: A (Remaster)", provider="spotify", episode_num=1),
    ]
    result = analyze_series(make_curation(albums=albums))
    dupes = result["duplicates_within_provider"]
    assert len(dupes) == 1
    assert dupes[0]["provider"] == "spotify"
    assert dupes[0]["episode_num"] == 1
    assert sorted(dupes[0]["album_ids"]) == ["a", "a2"]


def test_analyze_cross_provider_same_episode_is_not_a_duplicate():
    """Same episode on Spotify and Apple Music is expected, not a defect."""
    albums = [
        make_album("a", "Folge 1: A", provider="spotify", episode_num=1),
        make_album("b", "Folge 1: A", provider="apple_music", episode_num=1),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["duplicates_within_provider"] == []


def test_analyze_episodes_without_number_are_not_duplicates():
    """Multiple specials/None-numbered albums on the same provider don't count."""
    albums = [
        make_album("a", "Special: Pilot", provider="spotify"),
        make_album("b", "Special: Christmas", provider="spotify"),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["duplicates_within_provider"] == []


def test_analyze_duplicates_respect_overrides():
    """Excluding one of a pair via review override resolves the duplicate."""
    curation = make_curation(
        albums=[
            make_album("a", "Folge 1: A", provider="spotify", episode_num=1),
            make_album("b", "Folge 1: B", provider="spotify", episode_num=1),
        ],
        review={
            "overrides": [
                {"album_id": "b", "action": "exclude", "reason": "duplicate"},
            ],
        },
    )
    result = analyze_series(curation)
    assert result["duplicates_within_provider"] == []


def test_analyze_three_way_duplicate_lists_all_album_ids():
    albums = [
        make_album("a", "Folge 1: V1", provider="spotify", episode_num=1),
        make_album("b", "Folge 1: V2", provider="spotify", episode_num=1),
        make_album("c", "Folge 1: V3", provider="spotify", episode_num=1),
    ]
    result = analyze_series(make_curation(albums=albums))
    dupes = result["duplicates_within_provider"]
    assert len(dupes) == 1
    assert sorted(dupes[0]["album_ids"]) == ["a", "b", "c"]


# ── title_clusters ─────────────────────────────────────────────────────────


def test_analyze_uniform_titles_form_one_cluster():
    albums = [
        make_album(f"id{n}", f"Folge {n}: Episode {n}", episode_num=n)
        for n in range(1, 11)
    ]
    result = analyze_series(make_curation(albums=albums))
    clusters = result["title_clusters"]
    assert len(clusters) == 1
    assert clusters[0]["shape"] == "folge n"
    assert clusters[0]["count"] == 10
    assert len(clusters[0]["examples"]) <= 3


def test_analyze_clusters_sub_series_separately():
    """Mixed sub-series produce distinct clusters sorted by frequency."""
    albums = [
        make_album(f"main{n}", f"Folge {n}: Main", episode_num=n)
        for n in range(1, 11)
    ] + [
        make_album(f"junior{n}", f"Junior - Folge {n}: Sub", episode_num=n)
        for n in range(1, 4)
    ]
    result = analyze_series(make_curation(albums=albums))
    clusters = result["title_clusters"]
    shapes = [c["shape"] for c in clusters]
    assert "folge n" in shapes
    assert "junior - folge n" in shapes
    # Sorted by count desc
    assert clusters[0]["count"] >= clusters[1]["count"]


def test_analyze_clusters_use_slash_as_delimiter():
    """Older Die drei ??? convention 'NNN/title' is its own shape."""
    albums = [
        make_album("a", "051/und der riskante Ritt", episode_num=51),
        make_album("b", "050/und der verschwundene Filmstar", episode_num=50),
        make_album("c", "Folge 237: und der rote Büffel", episode_num=237),
    ]
    result = analyze_series(make_curation(albums=albums))
    shapes = {c["shape"] for c in result["title_clusters"] if c["count"] >= 2}
    assert "n" in shapes
    # Folge cluster has only one entry, so doesn't appear in clusters (count<2)
    assert "folge n" not in shapes


def test_analyze_singleton_shapes_excluded_from_clusters():
    """Shapes appearing once are outliers, not clusters."""
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
        make_album("c", "Best of 2020", episode_num=None),
    ]
    result = analyze_series(make_curation(albums=albums))
    shapes = [c["shape"] for c in result["title_clusters"]]
    assert shapes == ["folge n"]


def test_analyze_empty_clusters_when_no_albums():
    result = analyze_series(make_curation(albums=[]))
    assert result["title_clusters"] == []


def test_analyze_cluster_examples_are_real_titles():
    albums = [
        make_album("a", "Folge 1: First", episode_num=1),
        make_album("b", "Folge 2: Second", episode_num=2),
    ]
    result = analyze_series(make_curation(albums=albums))
    examples = result["title_clusters"][0]["examples"]
    assert "Folge 1: First" in examples
    assert "Folge 2: Second" in examples


# ── outliers ───────────────────────────────────────────────────────────────


def test_analyze_no_outliers_when_all_titles_share_a_shape():
    albums = [
        make_album(f"id{n}", f"Folge {n}: T", episode_num=n)
        for n in range(1, 6)
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["outliers"] == []
    assert result["outlier_count"] == 0


def test_analyze_singleton_title_surfaces_as_outlier():
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
        make_album("c", "Best of 2020"),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["outlier_count"] == 1
    assert len(result["outliers"]) == 1
    assert result["outliers"][0]["album_id"] == "c"
    assert result["outliers"][0]["title"] == "Best of 2020"
    assert result["outliers"][0]["shape"] == "best of n"


def test_analyze_outlier_list_capped_at_20():
    """Long outlier tails are capped, but outlier_count carries the truth."""
    import string
    chars = string.ascii_lowercase
    albums = [
        make_album(
            f"u{n}",
            f"Special edition {chars[n % 26]}{chars[(n // 26) % 26]} variant",
        )
        for n in range(50)
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["outlier_count"] == 50
    assert len(result["outliers"]) == 20


def test_analyze_outliers_exclude_clustered_titles():
    """Titles whose shape is shared with another are not outliers."""
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
        make_album("c", "Folge 3: C", episode_num=3),
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["outliers"] == []


# ── cross_provider_coverage ────────────────────────────────────────────────


def test_analyze_coverage_empty_for_no_albums():
    result = analyze_series(make_curation(albums=[]))
    assert result["cross_provider_coverage"] == {
        "by_provider": {},
        "missing_per_provider": {},
        "on_all_providers": 0,
    }


def test_analyze_coverage_single_provider_has_no_missing():
    albums = [
        make_album(f"a{n}", f"Folge {n}", provider="spotify", episode_num=n)
        for n in (1, 2, 3)
    ]
    result = analyze_series(make_curation(albums=albums))
    cov = result["cross_provider_coverage"]
    assert cov["by_provider"] == {"spotify": 3}
    assert cov["missing_per_provider"] == {}
    assert cov["on_all_providers"] == 3


def test_analyze_coverage_balanced_two_providers():
    albums = []
    for n in (1, 2, 3):
        albums.append(make_album(f"s{n}", f"Folge {n}", provider="spotify", episode_num=n))
        albums.append(make_album(f"a{n}", f"Folge {n}", provider="apple_music", episode_num=n))
    result = analyze_series(make_curation(albums=albums))
    cov = result["cross_provider_coverage"]
    assert cov["by_provider"] == {"spotify": 3, "apple_music": 3}
    assert cov["missing_per_provider"] == {}
    assert cov["on_all_providers"] == 3


def test_analyze_coverage_flags_asymmetric_providers():
    """Spotify has eps 1-3, Apple Music has 1 and 3 only. Apple is missing 2."""
    albums = [
        make_album("s1", "Folge 1", provider="spotify", episode_num=1),
        make_album("s2", "Folge 2", provider="spotify", episode_num=2),
        make_album("s3", "Folge 3", provider="spotify", episode_num=3),
        make_album("a1", "Folge 1", provider="apple_music", episode_num=1),
        make_album("a3", "Folge 3", provider="apple_music", episode_num=3),
    ]
    result = analyze_series(make_curation(albums=albums))
    cov = result["cross_provider_coverage"]
    assert cov["by_provider"] == {"spotify": 3, "apple_music": 2}
    assert cov["missing_per_provider"] == {"apple_music": [2]}
    assert cov["on_all_providers"] == 2


def test_analyze_coverage_ignores_albums_without_episode_num():
    """Specials without episode numbers can't be paired across providers."""
    albums = [
        make_album("s1", "Folge 1", provider="spotify", episode_num=1),
        make_album("a1", "Folge 1", provider="apple_music", episode_num=1),
        make_album("special", "Pilot", provider="spotify"),
    ]
    result = analyze_series(make_curation(albums=albums))
    cov = result["cross_provider_coverage"]
    assert cov["by_provider"] == {"spotify": 1, "apple_music": 1}
    assert cov["on_all_providers"] == 1


def test_analyze_coverage_respects_overrides():
    curation = make_curation(
        albums=[
            make_album("s1", "Folge 1", provider="spotify", episode_num=1),
            make_album("s2", "Folge 2", provider="spotify", episode_num=2),
            make_album("a1", "Folge 1", provider="apple_music", episode_num=1),
        ],
        review={
            "overrides": [
                {"album_id": "s2", "action": "exclude", "reason": "wrong content"},
            ],
        },
    )
    result = analyze_series(curation)
    assert result["cross_provider_coverage"]["missing_per_provider"] == {}


# ── pattern_coverage ───────────────────────────────────────────────────────


def test_analyze_pattern_coverage_empty_curation():
    result = analyze_series(make_curation(albums=[]))
    assert result["pattern_coverage"] == {"percentage": 0.0, "missing": 0}


def test_analyze_pattern_coverage_full_match():
    albums = [
        make_album(f"id{n}", f"Folge {n}: T", episode_num=n)
        for n in range(1, 11)
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["pattern_coverage"] == {"percentage": 100.0, "missing": 0}


def test_analyze_pattern_coverage_partial_match():
    albums = [
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
        make_album("c", "Special: Pilot"),
    ]
    result = analyze_series(make_curation(albums=albums))
    cov = result["pattern_coverage"]
    assert cov["missing"] == 1
    assert cov["percentage"] == pytest.approx(66.7, abs=0.1)


def test_analyze_pattern_coverage_zero_match():
    albums = [
        make_album(f"id{n}", f"Special {n}")
        for n in range(3)
    ]
    result = analyze_series(make_curation(albums=albums))
    assert result["pattern_coverage"] == {"percentage": 0.0, "missing": 3}


# ── interaction with overrides ─────────────────────────────────────────────


def test_analyze_excludes_albums_marked_via_review_override():
    curation = make_curation(
        albums=[
            make_album("a", "Folge 1: A", episode_num=1),
            make_album("b", "Folge 2: B", episode_num=2),
            make_album("c", "Folge 3: C", episode_num=3),
        ],
        review={
            "overrides": [
                {"album_id": "b", "action": "exclude", "reason": "duplicate"},
            ],
        },
    )
    result = analyze_series(curation)
    assert result["total"] == 2
    assert result["with_episode_num"] == 2
    assert result["gaps"] == [2]
