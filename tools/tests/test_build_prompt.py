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
    """The closing instruction guides the agent to propose actions."""
    curation = make_curation(albums=[make_album("a", "Folge 1: A", episode_num=1)])
    prompt = _build_prompt(curation)
    assert "overrides" in prompt
    assert "splits" in prompt
    assert "web_search" in prompt or "fetch_page" in prompt
