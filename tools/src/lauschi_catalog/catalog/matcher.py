"""Episode pattern matching utilities.

Episode numbers exist only inside album titles — neither provider exposes
them as metadata — so this regex extraction is the single place they are
derived. The app consumes the curated result and never re-derives it (see
docs/catalog-episode-numbers.md).

Patterns are used exactly as written. Over-escaped shortcuts are rejected
where they enter, by curate_ops._validate_episode_pattern and
validate_ops.validate_l1, rather than silently repaired here: a repair
made a broken lieselotte_filmhoerspiele pattern work in the pipeline
while the app could not match it for months.
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
        if not m:
            continue
        # Walk the groups: with alternation like (?:^Folge (\d+):)|(?:^(\d+)/)
        # the match may land on a later alternative, leaving group 1 empty.
        # Leftmost non-empty wins, so the most specific alternative is
        # preferred.
        for group in m.groups():
            if group is None:
                continue
            try:
                return int(group)
            except (TypeError, ValueError):
                continue
    return None


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
