"""Tests for lauschi_catalog.catalog.add_ops."""

from __future__ import annotations

import pytest

from lauschi_catalog.catalog.add_ops import _PATTERNS, which_pattern


@pytest.mark.parametrize(
    ("title", "expected_name"),
    [
        ("Folge 12: Title", "Folge N"),
        ("Teil 3", "Teil N"),
        ("Episode 5: X", "Episode N"),
        ("Fall 7", "Fall N"),
        ("Band 2", "Band N"),
        ("Hörspiel 4", "Hörspiel N"),
        ("Nr. 12 Foo", "Nr. N"),
        ("12: Title", "N:"),
        ("123/Title", "NNN/"),
    ],
)
def test_which_pattern_matches_at_start(title: str, expected_name: str) -> None:
    result = which_pattern(title)
    assert result is not None
    assert result[0] == expected_name


def test_which_pattern_anchors_to_start() -> None:
    """Mid-string numbering must not match (SKILL.md:112)."""
    assert which_pattern("Foo Folge 12: Bar") is None
    assert which_pattern("Foo Nr. 12 Bar") is None


def test_patterns_are_anchored() -> None:
    for name, pat in _PATTERNS:
        assert pat.startswith("^"), f"{name} is not anchored"
