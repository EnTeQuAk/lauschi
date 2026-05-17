"""Tests for review._build_prompt.

The prompt is what the agent reads, so its construction is part of the
review's correctness story. These tests pin the structural shape:
included/excluded album lists, content_type branching, override-aware
inclusion, and large-list handling.
"""

from __future__ import annotations

import json

from lauschi_catalog.commands.review import _build_prompt

from .conftest import make_album, make_curation


def test_prompt_includes_series_metadata():
    curation = make_curation(
        series_id="tkkg",
        title="TKKG",
        episode_pattern=r"^Folge (\d+):",
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    )
    prompt = _build_prompt(curation)
    assert "tkkg" in prompt
    assert "TKKG" in prompt
    assert r"^Folge (\d+):" in prompt


def test_prompt_lists_all_included_albums():
    albums = [
        make_album(f"id{n}", f"Folge {n}: T", episode_num=n)
        for n in range(1, 6)
    ]
    curation = make_curation(albums=albums)
    prompt = _build_prompt(curation)
    for n in range(1, 6):
        assert f"Folge {n}: T" in prompt
        assert f"id{n}" in prompt


def test_prompt_excluded_section_caps_at_30():
    """Excluded list is capped to keep prompts bounded; total is announced."""
    albums = [make_album(f"e{n}", f"Excluded {n}", include=False) for n in range(50)]
    curation = make_curation(albums=albums)
    prompt = _build_prompt(curation)
    assert "and 20 more" in prompt
    assert "Excluded albums (50)" in prompt


def test_prompt_skips_albums_excluded_via_existing_overrides():
    """A previously-overridden album should not appear as ``included``."""
    curation = make_curation(
        albums=[
            make_album("keep", "Folge 1: Keep", episode_num=1),
            make_album("drop", "Folge 2: Drop", episode_num=2),
        ],
        review={
            "overrides": [
                {"album_id": "drop", "action": "exclude", "reason": "dup"},
            ],
        },
    )
    prompt = _build_prompt(curation)
    # Both album_ids appear somewhere in the prompt (analysis dump etc.),
    # but only "keep" is in the ✅ included section.
    included_section = prompt.split("### Included albums")[1].split("### Excluded")[0]
    assert "keep" in included_section
    assert "drop" not in included_section


def test_prompt_default_is_hoerspiel_no_music_branch():
    """Curations without content_type get the default Hörspiel treatment."""
    curation = make_curation(albums=[make_album("a", "Folge 1: A", episode_num=1)])
    prompt = _build_prompt(curation)
    assert "Music artist" not in prompt
    assert "Content type: hoerspiel" in prompt


def test_prompt_music_branch_emits_override_section():
    """content_type='music' triggers explicit guidance overriding Hörspiel rules."""
    curation = make_curation(
        albums=[make_album("a", "Some Song", episode_num=None)],
    )
    curation["content_type"] = "music"
    prompt = _build_prompt(curation)
    assert "Content type: music" in prompt
    assert "Music artist" in prompt
    assert "music singles" in prompt.lower() or "music releases" in prompt.lower()


def test_prompt_hoerspiel_does_not_emit_music_section():
    """Explicit content_type='hoerspiel' still skips the music branch."""
    curation = make_curation(albums=[make_album("a", "Folge 1: A", episode_num=1)])
    curation["content_type"] = "hoerspiel"
    prompt = _build_prompt(curation)
    assert "Music artist" not in prompt


def test_prompt_reflects_content_type_flip_from_prior_review():
    """A series that flipped from music to hoerspiel in the curation
    JSON should be reviewed with the hoerspiel rules, even if the
    prior review block was music-oriented. Defensive test for #137."""
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "status": "approved",
            "reviewed_at": "2026-01-01T00:00:00+00:00",
            "summary": "Previously reviewed as music",
        },
    )
    curation["content_type"] = "hoerspiel"
    prompt = _build_prompt(curation)
    assert "Content type: hoerspiel" in prompt
    assert "Music artist" not in prompt


def test_prompt_carries_structural_analysis_as_json():
    """The structural analysis is included so the agent doesn't recompute it."""
    curation = make_curation(albums=[
        make_album("a", "Folge 1: A", episode_num=1),
        make_album("b", "Folge 2: B", episode_num=2),
    ])
    prompt = _build_prompt(curation)
    # The analysis JSON is recognizable by its keys.
    assert '"title_clusters"' in prompt
    assert '"duplicates_within_provider"' in prompt
    assert '"cross_provider_coverage"' in prompt


def test_prompt_includes_provider_artist_ids():
    curation = make_curation(albums=[make_album("a", "Folge 1: A", episode_num=1)])
    curation["provider_artist_ids"] = {"spotify": ["s123"], "apple_music": ["a456"]}
    prompt = _build_prompt(curation)
    assert "s123" in prompt
    assert "a456" in prompt


def test_prompt_action_call_is_present():
    """The closing instruction points the agent at the proposal tools."""
    curation = make_curation(albums=[make_album("a", "Folge 1: A", episode_num=1)])
    prompt = _build_prompt(curation)
    # Each action category has a tool the agent should call.
    assert "propose_override" in prompt
    assert "propose_split" in prompt
    assert "add_album" in prompt
    assert "propose_pattern_update" in prompt
    assert "web_search" in prompt or "fetch_page" in prompt


# ── prior review state ────────────────────────────────────────────────────


def test_prompt_omits_prior_state_section_for_fresh_curation():
    """First-time review: no prior overrides/splits/summary, skip section."""
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
    )
    prompt = _build_prompt(curation)
    assert "Prior review state" not in prompt


def test_prompt_omits_prior_state_when_review_block_is_empty():
    """An empty review block (e.g., curate just stamped reviewed_at) is not prior state."""
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"reviewed_at": "2026-01-01"},
    )
    prompt = _build_prompt(curation)
    assert "Prior review state" not in prompt


def test_prompt_surfaces_prior_overrides():
    curation = make_curation(
        albums=[
            make_album("a", "Folge 1: A", episode_num=1),
            make_album("b", "Folge 2: B", episode_num=2),
        ],
        review={
            "status": "approved",
            "overrides": [
                {"album_id": "b", "provider": "spotify",
                 "action": "exclude", "reason": "duplicate of ep 2 keep older release"},
            ],
        },
    )
    prompt = _build_prompt(curation)
    assert "Prior review state" in prompt
    # Override details surfaced
    assert "exclude" in prompt
    # Album_id appears (so agent knows which album was already overridden)
    state_block = prompt.split("Prior review state")[1].split("Review the structure")[0]
    assert "b" in state_block  # album_id
    assert "duplicate" in state_block  # reason
    # Status surfaced so agent knows why review is re-running
    assert "status=approved" in state_block


def test_prompt_surfaces_prior_splits():
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "splits": [
                {"new_series_id": "sub_one", "new_series_title": "Sub One",
                 "album_ids": ["x", "y", "z"], "provider": "spotify",
                 "reason": "distinct sub-series with own numbering"},
            ],
        },
    )
    prompt = _build_prompt(curation)
    state_block = prompt.split("Prior review state")[1].split("Review the structure")[0]
    assert "sub_one" in state_block
    assert "3 albums" in state_block


def test_prompt_surfaces_prior_summary_truncated():
    long = "x" * 500
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={"summary": long},
    )
    prompt = _build_prompt(curation)
    assert "Prior review state" in prompt
    # Truncated to 300 chars in the prompt
    state_block = prompt.split("Prior review state")[1]
    # 300 x's max from the summary, followed by line wrap into other content
    summary_xs = state_block.split("x")
    assert len([s for s in summary_xs if s == ""]) <= 301


def test_prompt_includes_respect_instruction_when_prior_state_present():
    """The agent gets reminded to respect prior decisions inline."""
    curation = make_curation(
        albums=[make_album("a", "Folge 1: A", episode_num=1)],
        review={
            "overrides": [{"album_id": "a", "provider": "spotify",
                           "action": "exclude", "reason": "test"}],
        },
    )
    prompt = _build_prompt(curation)
    assert "deliberate decisions" in prompt or "Respect them" in prompt


def test_prompt_caps_displayed_overrides_at_10():
    overrides = [
        {"album_id": f"id{n}", "provider": "spotify",
         "action": "exclude", "reason": "test"}
        for n in range(15)
    ]
    curation = make_curation(
        albums=[make_album(f"id{n}", f"Folge {n}", episode_num=n) for n in range(15)],
        review={"overrides": overrides},
    )
    prompt = _build_prompt(curation)
    state_block = prompt.split("Prior review state")[1].split("Review the structure")[0]
    assert "and 5 more" in state_block
