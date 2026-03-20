"""Episode pattern matching utilities.

Ported from scripts/episode_util.py.
"""

from __future__ import annotations

import re


def extract_episode(
    pattern: str | list[str] | None,
    title: str,
) -> int | None:
    """Extract episode number from a title using one or more regex patterns.

    Each pattern must have at least one capture group for the episode number.
    Patterns are tried in order; first match wins.
    """
    if not pattern:
        return None
    patterns = [pattern] if isinstance(pattern, str) else pattern
    for p in patterns:
        m = re.search(p, title)
        if m and m.groups():
            try:
                g = m.group(1)
                if g is not None:
                    return int(g)
            except (ValueError, IndexError, TypeError):
                continue
    return None


def validate_pattern(pattern: str | list[str] | None) -> str | list[str] | None:
    """Validate episode patterns: each must have at least 1 capture group."""
    if pattern is None:
        return None
    items = [pattern] if isinstance(pattern, str) else pattern
    for p in items:
        c = re.compile(p)
        if c.groups < 1:
            msg = f"Pattern {p!r} must have at least 1 capture group, got {c.groups}"
            raise ValueError(msg)
    return items[0] if len(items) == 1 else items
