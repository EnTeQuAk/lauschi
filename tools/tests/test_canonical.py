"""Tests for catalog.canonical.canonicalize.

This is the single source of truth for on-disk curation shape, so
the rules are pinned hard: any future contributor adding a new
sortable list MUST add a test here, or diffs across re-runs will
silently regress.
"""

from __future__ import annotations

from copy import deepcopy

from lauschi_catalog.catalog.canonical import canonicalize


# ── albums ────────────────────────────────────────────────────────────────


def test_sorts_albums_by_provider_first():
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "s1", "title": "A", "episode_num": 1},
            {"provider": "apple_music", "album_id": "a1", "title": "A", "episode_num": 1},
        ],
    }
    canonicalize(data)
    assert [a["provider"] for a in data["albums"]] == ["apple_music", "spotify"]


def test_sorts_albums_by_episode_num_within_provider():
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "x", "title": "Folge 5", "episode_num": 5},
            {"provider": "spotify", "album_id": "y", "title": "Folge 1", "episode_num": 1},
            {"provider": "spotify", "album_id": "z", "title": "Folge 3", "episode_num": 3},
        ],
    }
    canonicalize(data)
    assert [a["episode_num"] for a in data["albums"]] == [1, 3, 5]


def test_sorts_unnumbered_albums_after_numbered_within_provider():
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "u1", "title": "Special", "episode_num": None},
            {"provider": "spotify", "album_id": "n1", "title": "Folge 1", "episode_num": 1},
            {"provider": "spotify", "album_id": "u2", "title": "Best Of", "episode_num": None},
        ],
    }
    canonicalize(data)
    ids = [a["album_id"] for a in data["albums"]]
    # Numbered first, then unnumbered alphabetically by title (Best Of < Special).
    assert ids == ["n1", "u2", "u1"]


def test_sorts_unnumbered_with_missing_episode_key_same_as_none():
    """Albums without episode_num at all sort identically to None."""
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "missing", "title": "Beta"},
            {"provider": "spotify", "album_id": "explicit", "title": "Alpha", "episode_num": None},
        ],
    }
    canonicalize(data)
    # Both unnumbered, sorted by title: Alpha < Beta.
    assert [a["album_id"] for a in data["albums"]] == ["explicit", "missing"]


def test_album_id_is_final_tiebreaker():
    """Two same-titled releases on same provider with same episode
    fall back to album_id so order is fully deterministic."""
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "z", "title": "Folge 1", "episode_num": 1},
            {"provider": "spotify", "album_id": "a", "title": "Folge 1", "episode_num": 1},
        ],
    }
    canonicalize(data)
    assert [a["album_id"] for a in data["albums"]] == ["a", "z"]


def test_corrupt_album_entry_does_not_crash():
    """Defense in depth: a non-dict in the list shouldn't kill the writer."""
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "real", "title": "T", "episode_num": 1},
            "junk",
        ],
    }
    canonicalize(data)
    assert len(data["albums"]) == 2


# ── provider_artist_ids ───────────────────────────────────────────────────


def test_sorts_provider_artist_id_lists():
    data = {"provider_artist_ids": {"spotify": ["z9", "a1", "m5"]}}
    canonicalize(data)
    assert data["provider_artist_ids"]["spotify"] == ["a1", "m5", "z9"]


def test_provider_artist_ids_dict_is_left_for_json_sort_keys():
    """Dict ordering is handled by json.dumps; the canonicalizer
    only touches list values."""
    data = {"provider_artist_ids": {"spotify": ["a"], "apple_music": ["b"]}}
    before_keys = list(data["provider_artist_ids"].keys())
    canonicalize(data)
    # Same keys, same order — we don't reorder dict keys.
    assert list(data["provider_artist_ids"].keys()) == before_keys


# ── review.overrides ──────────────────────────────────────────────────────


def test_sorts_overrides_by_provider_then_album_id():
    data = {
        "review": {
            "overrides": [
                {"provider": "spotify", "album_id": "z", "action": "exclude"},
                {"provider": "apple_music", "album_id": "m", "action": "exclude"},
                {"provider": "spotify", "album_id": "a", "action": "exclude"},
            ],
        },
    }
    canonicalize(data)
    pairs = [(o["provider"], o["album_id"]) for o in data["review"]["overrides"]]
    assert pairs == [("apple_music", "m"), ("spotify", "a"), ("spotify", "z")]


# ── review.splits ─────────────────────────────────────────────────────────


def test_sorts_splits_by_new_series_id():
    data = {
        "review": {
            "splits": [
                {"new_series_id": "z_sub", "album_ids": []},
                {"new_series_id": "a_sub", "album_ids": []},
                {"new_series_id": "m_sub", "album_ids": []},
            ],
        },
    }
    canonicalize(data)
    assert [s["new_series_id"] for s in data["review"]["splits"]] == [
        "a_sub", "m_sub", "z_sub",
    ]


def test_sorts_album_ids_inside_each_split():
    data = {
        "review": {
            "splits": [
                {"new_series_id": "sub", "album_ids": ["z", "a", "m"]},
            ],
        },
    }
    canonicalize(data)
    assert data["review"]["splits"][0]["album_ids"] == ["a", "m", "z"]


# ── review.added_albums ───────────────────────────────────────────────────


def test_sorts_added_albums_by_album_key():
    data = {
        "review": {
            "added_albums": [
                {"provider": "spotify", "album_id": "z", "title": "T", "episode_num": 5},
                {"provider": "spotify", "album_id": "a", "title": "T", "episode_num": 2},
            ],
        },
    }
    canonicalize(data)
    eps = [a["episode_num"] for a in data["review"]["added_albums"]]
    assert eps == [2, 5]


# ── intentional non-touching ──────────────────────────────────────────────


def test_does_not_reorder_aliases_or_keywords():
    """Both fields can carry curation intent in their order
    (primary alias first, etc.). Leave them alone."""
    data = {
        "aliases": ["Zorro", "Aaron"],
        "keywords": ["zebra", "apple"],
    }
    snapshot = deepcopy(data)
    canonicalize(data)
    assert data["aliases"] == snapshot["aliases"]
    assert data["keywords"] == snapshot["keywords"]


def test_does_not_reorder_top_level_keys():
    """Insertion order at the top level keeps related fields adjacent
    for humans reading the JSON."""
    data = {
        "id": "s1",
        "title": "T",
        "albums": [{"provider": "spotify", "album_id": "a", "title": "T", "episode_num": 1}],
        "review": {"status": "approved"},
    }
    before = list(data.keys())
    canonicalize(data)
    assert list(data.keys()) == before


# ── empty / missing edge cases ────────────────────────────────────────────


def test_empty_curation_does_not_crash():
    data: dict = {}
    canonicalize(data)
    assert data == {}


def test_curation_without_review_block_handled():
    data = {"albums": [{"provider": "spotify", "album_id": "a", "title": "T", "episode_num": 1}]}
    canonicalize(data)
    assert "review" not in data


def test_review_without_lists_handled():
    data = {"review": {"status": "approved"}}
    canonicalize(data)
    assert data["review"] == {"status": "approved"}


def test_idempotent():
    """Applying canonicalize twice produces the same result as once."""
    data = {
        "albums": [
            {"provider": "spotify", "album_id": "z", "title": "Z", "episode_num": 5},
            {"provider": "apple_music", "album_id": "a", "title": "A", "episode_num": 1},
            {"provider": "spotify", "album_id": "a", "title": "A", "episode_num": 1},
        ],
        "review": {
            "overrides": [
                {"provider": "spotify", "album_id": "z"},
                {"provider": "spotify", "album_id": "a"},
            ],
            "splits": [
                {"new_series_id": "b", "album_ids": ["c", "a"]},
                {"new_series_id": "a", "album_ids": ["z"]},
            ],
        },
    }
    once = deepcopy(data)
    canonicalize(once)
    twice = deepcopy(once)
    canonicalize(twice)
    assert once == twice
