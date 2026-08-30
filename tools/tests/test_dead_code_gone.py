"""Regression pins for removed helpers: if any of these come back, the
pipeline regains a path that ships unasked-for or invented data."""

from __future__ import annotations

import pytest

from lauschi_catalog.catalog import matcher, prompt
from lauschi_catalog.catalog.curate_ops import CurateDeps
from lauschi_catalog.commands import add


def test_curate_deps_has_no_seen_albums():
    """The unused seen_albums field was removed from CurateDeps."""
    assert not hasattr(CurateDeps, "seen_albums")
    with pytest.raises(TypeError):
        CurateDeps(seen_albums={})  # type: ignore[call-arg]


def test_matcher_no_preview_or_apply_helpers():
    """preview_episode_pattern and apply_episode_pattern were only used by a
    removed review agent; they should not return and lure future code back.
    """
    assert not hasattr(matcher, "preview_episode_pattern")
    assert not hasattr(matcher, "apply_episode_pattern")


def test_prompt_no_curation_album_to_dict():
    """curation_album_to_dict had zero callers; it was removed."""
    assert not hasattr(prompt, "curation_album_to_dict")


def test_add_command_no_all_reexports():
    """commands.add no longer re-exports library helpers via __all__."""
    assert not hasattr(add, "__all__")
