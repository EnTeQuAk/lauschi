"""Shared episode pattern utilities for curation scripts."""
from __future__ import annotations

import re


def extract_episode(
    pattern: str | list[str] | None, title: str,
) -> int | None:
    """Extract episode number from a title using one or more regex patterns.

    Each pattern must have exactly one capture group for the episode number.
    Patterns are tried in order; first match wins.
    """
    if not pattern:
        return None
    patterns = [pattern] if isinstance(pattern, str) else pattern
    for p in patterns:
        m = re.search(p, title)
        if m and m.groups():
            try:
                return int(m.group(1))
            except (ValueError, IndexError):
                continue
    return None


def validate_patterns(patterns: str | list[str] | None) -> str | list[str] | None:
    """Validate episode patterns — each must have exactly 1 capture group."""
    if patterns is None:
        return None
    items = [patterns] if isinstance(patterns, str) else patterns
    for p in items:
        c = re.compile(p)
        if c.groups != 1:
            msg = f"Pattern {p!r} must have exactly 1 capture group, got {c.groups}"
            raise ValueError(msg)
    # Keep as string if single pattern (backward compat)
    return items[0] if len(items) == 1 else items
