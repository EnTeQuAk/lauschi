"""Episode pattern matching utilities.

Ported from scripts/episode_util.py.
"""

from __future__ import annotations

import re

_OVER_ESCAPED = re.compile(r"\\\\([dDwWsShHbB])")


def _fix_escapes(pattern: str) -> str:
    r"""Collapse double-escaped regex shortcuts (\\d -> \d).

    LLMs generating JSON tool calls sometimes write \\\\d instead of
    \\d, which after JSON parsing becomes the literal two-char sequence
    ``\`` + ``d`` instead of the regex metacharacter ``\d``.
    """
    return _OVER_ESCAPED.sub(r"\\\1", pattern)


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
        m = re.search(_fix_escapes(p), title)
        if m and m.groups():
            try:
                g = m.group(1)
                if g is not None:
                    return int(g)
            except (ValueError, IndexError, TypeError):
                continue
    return None


def validate_pattern(pattern: str | list[str] | None) -> str | list[str] | None:
    """Validate episode patterns: each must have at least 1 capture group.

    Also normalizes over-escaped regex shortcuts from LLM output.
    """
    if pattern is None:
        return None
    raw = [pattern] if isinstance(pattern, str) else pattern
    items = [_fix_escapes(p) for p in raw]
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


def _spread_sample(items: list, n: int) -> list:
    """Pick up to ``n`` items spread evenly across ``items``.

    Provider APIs return albums in a specific order (e.g. newest-first).
    Taking the first N blinds the model to era-specific naming. Spreading
    across the list surfaces early, middle, and late naming conventions.
    """
    if len(items) <= n:
        return items
    step = len(items) / n
    return [items[int(i * step)] for i in range(n)]


def compute_pattern_coverage(
    titles: list[str],
    pattern: str | list[str],
    *,
    max_samples: int = 5,
) -> dict:
    """Test ``pattern`` against ``titles`` and bucket failures by mode.

    Two distinct failure modes — without distinguishing them, an
    agent given ``(.*)`` sees 0% coverage and assumes "regex didn't
    match" (false: every title matched, but ``int(group)`` rejected
    the captured strings). The agent then loops trying broader
    regexes until it times out.

    Returns ``unmatched_regex_samples`` for titles where no pattern
    matched, and ``non_numeric_capture_samples`` for titles where a
    pattern matched but capture group 1 was non-numeric. The agent
    can read these and pick the right fix.

    Used by curate's metadata agent (check_pattern_coverage tool) and
    the output_validator (coverage floor enforcement). Lives in
    matcher.py so both consumers share one implementation.
    """
    patterns = [pattern] if isinstance(pattern, str) else list(pattern)
    patterns = [_fix_escapes(p) for p in patterns]
    if not patterns:
        return {"error": "pattern must be non-empty"}
    compiled: list[re.Pattern[str]] = []
    for p in patterns:
        try:
            c = re.compile(p)
        except re.error as e:
            return {"error": f"invalid regex {p!r}: {e}"}
        if c.groups < 1:
            return {"error": f"pattern {p!r}: needs ≥1 capture group"}
        compiled.append(c)

    matched = 0
    no_match: list[str] = []
    non_numeric: list[dict[str, str]] = []
    for title in titles:
        outcome = "no_match"
        captured: str | None = None
        for c in compiled:
            m = c.search(title)
            if not m or not m.groups():
                continue
            g = m.group(1)
            if g is None:
                continue
            try:
                int(g)
            except (TypeError, ValueError):
                # Track first non-numeric capture as evidence, but
                # keep trying alternatives — another pattern in the
                # list might still capture a digit on this title.
                if outcome == "no_match":
                    outcome = "non_numeric"
                    captured = g
                continue
            outcome = "matched"
            break

        if outcome == "matched":
            matched += 1
        elif outcome == "non_numeric":
            non_numeric.append({"title": title, "captured": captured or ""})
        elif outcome == "no_match":
            no_match.append(title)

    total = len(titles)
    coverage = round(matched / total, 3) if total else 0.0
    return {
        "pattern": pattern,
        "matched": matched,
        "total": total,
        "coverage": coverage,
        "unmatched_regex_samples": _spread_sample(no_match, max_samples),
        "non_numeric_capture_samples": _spread_sample(non_numeric, max_samples),
    }
