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


def preview_episode_pattern(
    albums: list[dict],
    pattern: str | list[str],
) -> int:
    """Count how many albums would have their ``episode_num`` changed if
    ``pattern`` were applied.

    Used by the review agent to gauge whether a proposed pattern is an
    improvement before committing to it. Pure: does not mutate inputs.
    """
    changed = 0
    for a in albums:
        ep = extract_episode(pattern, a.get("title", ""))
        if ep is not None and a.get("episode_num") != ep:
            changed += 1
    return changed


def apply_episode_pattern(
    albums: list[dict],
    pattern: str | list[str],
) -> list[dict]:
    """Return a new album list with episode_num re-extracted from titles.

    Albums whose title doesn't match keep their existing ``episode_num``.
    The input list and its dicts are not mutated; callers receive shallow
    copies.
    """
    out: list[dict] = []
    for a in albums:
        new_a = dict(a)
        ep = extract_episode(pattern, a.get("title", ""))
        if ep is not None:
            new_a["episode_num"] = ep
        out.append(new_a)
    return out
