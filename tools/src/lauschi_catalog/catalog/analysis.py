"""Structural analysis of curated series data.

Pure data processing: no LLM dependencies, no provider I/O. This is the
deterministic backbone the AI review agent reasons against. Keeping it
in its own module makes it cheap to test in isolation and prevents the
review prompt from relying on undocumented heuristics.
"""

from __future__ import annotations

import re
from collections import Counter
from typing import Any


def effective_albums(curation: dict) -> list[dict]:
    """Return included albums.

    Album include flags are the single source of truth: audit overrides
    materialize into them at audit time (``review.overrides`` is a
    trail, not an active filter).
    """
    return [a for a in curation.get("albums", []) if a.get("include")]


_CLUSTER_DELIMITERS = (":", "/", " - ", " | ")
_CLUSTER_EXAMPLE_LIMIT = 3
_OUTLIER_LIST_LIMIT = 20


def _title_shape(title: str) -> str:
    """Reduce a title to its structural shape for clustering.

    Lowercases, truncates at the first structural delimiter (``:``, ``/``,
    ``" - "``, ``" | "``), then collapses digit-runs to ``n``. Titles that
    share a naming convention end up with the same shape regardless of
    the specific episode number or subtitle.

    The dash and pipe forms are spaced (`` - `` not ``-``) so we don't
    truncate inside hyphenated words like ``Gute-Nacht-Geschichten``.

    Examples:
        "Folge 168: Die Elchkuh" → "folge n"
        "Junior - Folge 5: Sub" → "junior"
        "051/und der riskante Ritt" → "n"
        "Woodwalkers - Carags Verwandlung" → "woodwalkers"
    """
    s = title.lower()
    cuts = [s.index(d) for d in _CLUSTER_DELIMITERS if d in s]
    if cuts:
        s = s[: min(cuts)]
    return re.sub(r"\d+", "n", s).strip()


def _group_by_shape(albums: list[dict]) -> dict[str, list[dict]]:
    by_shape: dict[str, list[dict]] = {}
    for a in albums:
        by_shape.setdefault(_title_shape(a["title"]), []).append(a)
    return by_shape


def _title_clusters(by_shape: dict[str, list[dict]]) -> list[dict]:
    """Shapes with two or more members, sorted by descending count.

    Singleton shapes are intentionally excluded; they surface separately
    as outliers. Each cluster carries up to ``_CLUSTER_EXAMPLE_LIMIT``
    real titles to anchor the agent's judgment.
    """
    clusters = [
        {
            "shape": shape,
            "count": len(group),
            "examples": [a["title"] for a in group[:_CLUSTER_EXAMPLE_LIMIT]],
        }
        for shape, group in by_shape.items()
        if len(group) >= 2
    ]
    clusters.sort(key=lambda c: (-c["count"], c["shape"]))
    return clusters


def _outliers(by_shape: dict[str, list[dict]]) -> tuple[list[dict], int]:
    """Albums with title shapes appearing exactly once.

    Returns (sample, total). The sample is capped at ``_OUTLIER_LIST_LIMIT``
    to keep prompts bounded; the total reports the real count so the agent
    knows when it's seeing a slice of a long tail.
    """
    items = [
        {"album_id": group[0]["album_id"], "title": group[0]["title"], "shape": shape}
        for shape, group in by_shape.items()
        if len(group) == 1
    ]
    items.sort(key=lambda x: x["title"])
    return items[:_OUTLIER_LIST_LIMIT], len(items)


def _cross_provider_coverage(albums: list[dict]) -> dict:
    """Per-provider episode presence and asymmetry between providers.

    For each provider, reports how many distinct episode numbers are
    covered. ``missing_per_provider`` lists episodes present on at least
    one other provider but absent here, sorted ascending. Albums without
    an episode number cannot be paired across providers and are excluded
    from this analysis (they still appear in totals/clusters).
    """
    eps_by_provider: dict[str, set[int]] = {}
    for a in albums:
        ep = a.get("episode_num")
        if not ep:
            continue
        eps_by_provider.setdefault(a.get("provider", "spotify"), set()).add(ep)

    if not eps_by_provider:
        return {
            "by_provider": {},
            "missing_per_provider": {},
            "on_all_providers": 0,
        }

    all_eps: set[int] = set().union(*eps_by_provider.values())
    on_all = set.intersection(*eps_by_provider.values())

    missing = {p: sorted(all_eps - eps) for p, eps in eps_by_provider.items()}
    return {
        "by_provider": {p: len(eps) for p, eps in eps_by_provider.items()},
        "missing_per_provider": {p: m for p, m in missing.items() if m},
        "on_all_providers": len(on_all),
    }


def _duplicates_within_provider(albums: list[dict]) -> list[dict]:
    """Find (provider, episode_num) pairs assigned to more than one album.

    Cross-provider duplicates are intentionally ignored: the same episode
    appearing on both Spotify and Apple Music is the expected case. Albums
    without an episode number cannot be checked this way and are skipped.
    """
    by_key: dict[tuple[str, int], list[str]] = {}
    for a in albums:
        ep = a.get("episode_num")
        if not ep:
            continue
        key = (a.get("provider", "spotify"), ep)
        by_key.setdefault(key, []).append(a["album_id"])
    return [
        {"provider": p, "episode_num": e, "album_ids": ids}
        for (p, e), ids in by_key.items()
        if len(ids) > 1
    ]


def analyze_series(curation: dict) -> dict[str, Any]:
    """Compute structural facts about a curation for the review prompt.

    Returns a dict with deterministic summaries the AI does not need to
    rediscover. Pre-computing these prevents the agent from looping while
    trying to spot patterns that integer math can confirm in microseconds.

    Fields:
        total: number of effectively-included albums
        with_episode_num: of those, how many have an extracted episode_num
        episode_range: ``"min-max"`` or ``"none"``
        gaps: missing episode numbers in the range
        providers: per-provider album count
        common_words: top 10 content words across titles, noise stripped
        duplicates_within_provider: same provider + same episode_num
            collisions (a real defect, distinct from cross-provider pairs)
        title_clusters: groups of titles sharing a structural shape; useful
            for spotting sub-series mixed into a main series curation
        outliers: albums whose title shape appears only once. Capped at
            ``_OUTLIER_LIST_LIMIT`` items.
        outlier_count: total number of singleton shapes (may exceed
            ``len(outliers)`` when capped)
        cross_provider_coverage: per-provider episode counts plus the
            episode numbers each provider is missing relative to others
        pattern_coverage: ratio of albums for which episode_pattern
            extracted a number, plus the count that didn't. Low coverage
            with otherwise-clean titles signals a broken pattern.
    """
    albums = effective_albums(curation)
    episodes = [a for a in albums if a.get("episode_num")]
    nums = sorted(a["episode_num"] for a in episodes)

    gaps: list[int] = []
    if nums:
        for i in range(nums[0], nums[-1] + 1):
            if i not in nums:
                gaps.append(i)

    title_counter: Counter[str] = Counter()
    for a in albums:
        # Strip parenthetical content first, then collapse digits, the
        # noise prefixes "folge"/"teil", and any non-word punctuation
        # (including the "/" used in older NNN/Title naming) into spaces
        # so words come out clean.
        cleaned = re.sub(r"\(.*?\)", "", a["title"].lower())
        cleaned = re.sub(r"[^\w\s]|\d+|\bfolge\b|\bteil\b", " ", cleaned)
        for w in cleaned.split():
            if len(w) > 3:
                title_counter[w] += 1

    providers = Counter(a.get("provider", "spotify") for a in albums)
    by_shape = _group_by_shape(albums)
    outliers, outlier_count = _outliers(by_shape)

    return {
        "total": len(albums),
        "with_episode_num": len(episodes),
        "episode_range": f"{nums[0]}-{nums[-1]}" if nums else "none",
        "gaps": gaps,
        "providers": dict(providers),
        "common_words": title_counter.most_common(10),
        "duplicates_within_provider": _duplicates_within_provider(albums),
        "title_clusters": _title_clusters(by_shape),
        "outliers": outliers,
        "outlier_count": outlier_count,
        "cross_provider_coverage": _cross_provider_coverage(albums),
        "pattern_coverage": {
            "percentage": round(len(episodes) / len(albums) * 100, 1)
            if albums
            else 0.0,
            "missing": len(albums) - len(episodes),
        },
    }
