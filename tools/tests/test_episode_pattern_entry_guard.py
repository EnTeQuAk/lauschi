"""The entry guard on AI-produced episode patterns.

Patterns reach the catalog from the curation agent's structured output.
`_validate_episode_pattern` runs as a pydantic field validator there, so
a rejected pattern makes the agent retry rather than persisting a broken
one.

It has always required a capture group. It must also reject
double-escaped shortcuts: `'^Folge (\\d+):'` compiles happily but matches
a literal backslash, so it silently never fires. That exact pattern sat in
lieselotte_filmhoerspiele for months, hidden because the extractor
repaired it in passing instead of refusing it. Rejecting at the point of
entry is what makes that repair unnecessary.
"""

import pytest

from lauschi_catalog.catalog.curate_ops import _validate_episode_pattern


@pytest.mark.parametrize(
    "pattern",
    [
        pytest.param(r"^Folge (\d+):", id="a normal pattern"),
        pytest.param(None, id="none"),
        pytest.param([r"^Folge (\d+):", r"^Teil (\d+):"], id="a pattern list"),
    ],
)
def test_accepts_what_it_is_given_back_unchanged(pattern):
    assert _validate_episode_pattern(pattern) == pattern


def test_rejects_a_pattern_without_a_capture_group():
    with pytest.raises(ValueError, match="capture group"):
        _validate_episode_pattern(r"^Folge \d+:")


def test_rejects_a_double_escaped_shortcut():
    with pytest.raises(ValueError, match="double-escaped"):
        _validate_episode_pattern("^Folge (\\\\d+):")


def test_rejects_a_double_escaped_shortcut_inside_a_list():
    with pytest.raises(ValueError, match="double-escaped"):
        _validate_episode_pattern([r"^Folge (\d+):", "^Teil (\\\\d+):"])


@pytest.mark.parametrize("shortcut", ["d", "w", "s", "b"])
def test_rejects_every_double_escaped_class(shortcut):
    with pytest.raises(ValueError, match="double-escaped"):
        _validate_episode_pattern(f"^x (\\\\{shortcut}+):")
