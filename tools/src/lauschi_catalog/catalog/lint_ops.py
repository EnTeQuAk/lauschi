"""Deterministic lint checks for curation correctness.

Runs standalone, as part of the pipeline, and as a tool inside the
curate finalize agent for self-correction. Uses series_facts
(era_boundaries, known_gaps, etc.) to catch structural invariants.

Lint rules are generic (apply to every Hörspiel series). Per-series
facts (discovered by curate, audited by a second model) guide the
checks so they don't fire false positives on documented quirks.
"""

from __future__ import annotations

from datetime import date

from lauschi_catalog.catalog.facts import SeriesFacts
from lauschi_catalog.catalog.matcher import extract_episode

# Issues with this prefix are hard-gate: the audit phase refuses to
# auto-approve while any are present, regardless of the audit model's
# verdict. Everything else is advisory context for the auditor.
CRITICAL_PREFIX = "CRITICAL: "


def critical_issues(issues: list[str]) -> list[str]:
    """Filter issues down to the hard-gate ones."""
    return [i for i in issues if i.startswith(CRITICAL_PREFIX)]


def _included_count(curation: dict) -> int:
    return sum(1 for a in curation.get("albums", []) if a.get("include"))


def _facts_count(curation: dict) -> int:
    facts = curation.get("series_facts") or {}
    return sum(
        len(facts.get(k) or []) for k in ("era_boundaries", "known_gaps", "sub_series")
    )


def lint_regression(previous: dict | None, current: dict) -> list[str]:
    """Compare a re-curation against the previous curation.

    A model that silently empties a series (every album stamped
    music_single) or wipes discovered facts produces a structurally
    valid curation; only the comparison with what was there before
    makes the damage visible. CRITICAL issues here feed the audit
    hard-gate.
    """
    if not previous:
        return []
    issues: list[str] = []

    prev_inc = _included_count(previous)
    cur_inc = _included_count(current)
    if prev_inc > 0 and cur_inc == 0:
        issues.append(
            f"{CRITICAL_PREFIX}Include collapse: 0 included "
            f"(previous curation had {prev_inc})",
        )
    elif prev_inc > 0 and cur_inc < prev_inc * 0.5:
        issues.append(
            f"{CRITICAL_PREFIX}Included count dropped more than half: "
            f"{prev_inc} -> {cur_inc}",
        )

    if _facts_count(previous) > 0 and _facts_count(current) == 0:
        issues.append(
            f"{CRITICAL_PREFIX}series_facts lost: previous curation had "
            f"{_facts_count(previous)} facts, this one has none",
        )

    return issues


def _norm_title(title: str) -> str:
    """Normalize a title for cross-provider comparison.

    Apple Music decorates with ' - EP' / ' - Single' suffixes that
    Spotify doesn't carry.
    """
    t = " ".join(title.casefold().split())
    for suffix in (" - ep", " - single"):
        t = t.removesuffix(suffix)
    return t


def lint_curation(curation: dict, *, today: date | None = None) -> list[str]:
    """Run deterministic checks on a curation.

    Returns a list of human-readable issue strings. Empty list means
    no issues found. These issues are NOT escalations; they are
    warnings surfaced in the pipeline output for human review.
    """
    issues: list[str] = []
    albums = curation.get("albums", [])
    facts_dict = curation.get("series_facts")
    facts: SeriesFacts | None = None
    if facts_dict:
        try:
            facts = SeriesFacts.model_validate(facts_dict)
        except Exception as e:
            # Don't crash lint because a bad fact shape sneaked in.
            # Surface it as an issue so the human can fix it.
            issues.append(f"[malformed series_facts: {type(e).__name__}: {e}]")
    pattern = curation.get("episode_pattern")

    included = [a for a in albums if a.get("include")]
    # All episode numbers per provider (allowing duplicates for detection)
    eps_by_provider: dict[str, list[int]] = {}
    eps_albums_by_provider: dict[str, dict[int, list[dict]]] = {}
    for a in included:
        ep = a.get("episode_num")
        if ep is not None:
            prov = a.get("provider", "?")
            eps_by_provider.setdefault(prov, []).append(ep)
            eps_albums_by_provider.setdefault(prov, {}).setdefault(ep, []).append(a)

    # ── Rule 1: Episode numbers unique per provider per era ─────────
    if facts and facts.era_boundaries:
        for prov in eps_albums_by_provider:
            for era in facts.era_boundaries:
                rng = era.release_date_range
                if "-" not in rng:
                    continue
                parts = rng.split("-")
                start_y = int(parts[0].strip())
                end_y = int(parts[1].strip()) if parts[1].strip() else 9999
                era_eps: list[int] = []
                for ep, ep_albums in eps_albums_by_provider[prov].items():
                    for a in ep_albums:
                        if _year(a.get("release_date", "")) in range(start_y, end_y + 1):
                            era_eps.append(ep)
                dupes = _find_duplicates(era_eps)
                if dupes:
                    issues.append(
                        f"[{prov}] Duplicate episode numbers within era "
                        f"'{era.label}': {dupes}"
                    )
    else:
        # No era boundaries: just check globally per provider
        for prov, eps in eps_by_provider.items():
            dupes = _find_duplicates(eps)
            if dupes:
                issues.append(f"[{prov}] Duplicate episode numbers: {dupes}")

    # ── Rule 2: Unknown gaps ─────────────────────────────────────────
    for prov, eps in eps_by_provider.items():
        nums = sorted(set(eps))
        if len(nums) < 2:
            continue
        gaps = _find_gaps(nums)
        # Filter out known gaps
        known = {g.number for g in (facts.known_gaps if facts else [])}
        unknown = [g for g in gaps if g not in known]
        if unknown:
            issues.append(f"[{prov}] Unexpected gaps at episodes: {unknown}")

    # ── Rule 3: Episode N included but N-1 from same era excluded ─────
    excluded = [a for a in albums if not a.get("include")]
    excluded_eps: dict[str, dict[int, dict]] = {}
    for a in excluded:
        ep = a.get("episode_num")
        if ep is not None:
            prov = a.get("provider", "?")
            excluded_eps.setdefault(prov, {})[ep] = a

    for prov, inc_eps in eps_by_provider.items():
        exc_eps = excluded_eps.get(prov, {})
        for ep in sorted(set(inc_eps)):
            if ep <= 1:
                continue
            prev = ep - 1
            if prev not in inc_eps and prev not in exc_eps:
                # prev is not in the curation at all; that's a gap (Rule 2)
                continue
            if prev in exc_eps:
                reason = exc_eps[prev].get("exclude_reason", "")
                if not reason:
                    issues.append(
                        f"[{prov}] Episode {ep} included but {prev} "
                        f"excluded without reason"
                    )

    # ── Rule 4: Pattern coverage < 80% ───────────────────────────────
    if pattern and included:
        matched = sum(
            1
            for a in included
            if extract_episode(pattern, a.get("title", "")) is not None
        )
        coverage = matched / len(included)
        if coverage < 0.8:
            issues.append(
                f"Pattern coverage {coverage:.0%} ({matched}/{len(included)}) — "
                f"below 80% threshold"
            )

    # ── Rule 5: Cross-provider asymmetry ─────────────────────────────
    # Group by pattern (present providers -> missing provider) so a series
    # with 50 episodes missing on one provider produces one line, not 50.
    all_providers = sorted({a.get("provider", "?") for a in albums})
    if len(all_providers) > 1:
        # Collect episode numbers by (present_key, missing_provider, reason_type)
        asym: dict[tuple[str, str, str], list[int]] = {}
        for ep in set().union(*[set(eps) for eps in eps_by_provider.values()]):
            present = {prov for prov, eps in eps_by_provider.items() if ep in eps}
            missing = set(all_providers) - present
            for prov in missing:
                exc = excluded_eps.get(prov, {})
                if ep not in exc:
                    reason_type = "not even excluded"
                elif not exc[ep].get("exclude_reason"):
                    reason_type = "excluded without reason"
                else:
                    continue  # properly excluded, not an asymmetry
                key = (
                    ",".join(sorted(present)),
                    prov,
                    reason_type,
                )
                asym.setdefault(key, []).append(ep)

        for (present_key, prov, reason_type), eps in sorted(asym.items()):
            eps_str = _compress_runs(sorted(eps))
            issues.append(
                f"Episodes {eps_str} on {present_key} but {reason_type} on {prov}"
            )

    # ── Rule 6: Unaudited facts ─────────────────────────────────────
    if facts:
        for e in facts.era_boundaries:
            if not e.audited_by:
                issues.append(f"Unaudited era_boundary '{e.label}'")
        for g in facts.known_gaps:
            if not g.audited_by:
                issues.append(f"Unaudited known_gap ep {g.number}")
        for s in facts.sub_series:
            if not s.audited_by:
                issues.append(f"Unaudited sub_series '{s.label}'")

    # ── Rule 7: Low-confidence clusters ──────────────────────────────
    low_conf = [a for a in albums if a.get("confidence") in ("medium", "low")]
    total_decisions = len(albums)
    if low_conf:
        threshold = max(5, total_decisions // 10)
        if len(low_conf) > threshold:
            issues.append(
                f"[low_confidence_cluster] {len(low_conf)} decisions are "
                f"MEDIUM or LOW confidence (> {threshold}). Review their "
                f"`notes` fields."
            )

    # ── Rule 8: Auto-included albums (agent omissions) ──────────────
    auto_included = [a for a in albums if "auto-included" in (a.get("notes") or "")]
    if auto_included:
        titles = [a.get("title", "?") for a in auto_included[:5]]
        suffix = (
            f" (and {len(auto_included) - 5} more)" if len(auto_included) > 5 else ""
        )
        issues.append(
            f"[auto_included] {len(auto_included)} album(s) were auto-included "
            f"because the agent omitted them: {', '.join(titles)}{suffix}"
        )

    # ── Rule 9: Future-dated releases ────────────────────────────────
    # Deterministic on purpose: models date-reason from their training
    # cutoff (an auditor once flagged a three-month-old release as
    # "future"). Code knows what day it is.
    cutoff = (today or date.today()).isoformat()
    future = [
        a
        for a in included
        if len(a.get("release_date") or "") == 10 and a["release_date"] > cutoff
    ]
    if future:
        titles = [f"{a.get('title', '?')} ({a['release_date']})" for a in future[:5]]
        issues.append(
            f"[future_release] {len(future)} included album(s) dated in the "
            f"future: {', '.join(titles)}"
        )

    # ── Rule 10: Episode-number sanity ───────────────────────────────
    # episode_num >= 1000 is almost always a year captured by an
    # over-broad regex; <= 0 is never a real episode.
    insane = [
        a
        for a in included
        if a.get("episode_num") is not None and not (0 < a["episode_num"] < 1000)
    ]
    if insane:
        pairs = [f"{a.get('title', '?')!r} -> {a['episode_num']}" for a in insane[:5]]
        issues.append(
            f"[episode_num_sanity] {len(insane)} implausible episode_num "
            f"value(s): {', '.join(pairs)}"
        )

    # ── Rule 11: Cross-provider title counterparts ───────────────────
    # Same normalized title included on one provider but excluded on
    # another with a CONTENT-classifying reason: the same content can't
    # be a music_single there and an episode here. Redundancy reasons
    # (duplicate) are deliberate and stay silent, matching Rule 5's
    # "properly excluded" convention. Complements Rule 5, which needs
    # episode numbers; this catches the unnumbered case (music albums).
    contradictory_reasons = {
        "music_single",
        "compilation",
        "wrong_content_type",
        "sub_series_bleed",
    }
    included_titles: dict[str, str] = {}
    for a in included:
        included_titles.setdefault(
            _norm_title(a.get("title") or ""), a.get("provider", "?")
        )
    for a in albums:
        if a.get("include") or a.get("exclude_reason") not in contradictory_reasons:
            continue
        norm = _norm_title(a.get("title") or "")
        other = included_titles.get(norm)
        if other and other != a.get("provider"):
            issues.append(
                f"[title_counterpart] {a.get('title', '?')!r} excluded on "
                f"{a.get('provider', '?')} ({a.get('exclude_reason')}) but its "
                f"counterpart is included on {other}"
            )

    return issues


def _year(release_date: str) -> int:
    """Extract year from ISO date (YYYY-MM-DD) or YYYY string."""
    if not release_date:
        return 0
    # Accept "YYYY" or "YYYY-MM-DD" only; anything else returns 0
    if len(release_date) == 4:
        try:
            return int(release_date)
        except ValueError:
            return 0
    if len(release_date) >= 10 and release_date[4] == "-" and release_date[7] == "-":
        try:
            return int(release_date[:4])
        except ValueError:
            return 0
    return 0


def _compress_runs(nums: list[int]) -> str:
    """Compress a sorted list of integers into run notation.

    1,2,3,5,6,8 -> "1-3, 5-6, 8"
    """
    if not nums:
        return ""
    runs: list[str] = []
    start = prev = nums[0]
    for n in nums[1:]:
        if n == prev + 1:
            prev = n
        else:
            runs.append(f"{start}-{prev}" if prev > start else str(start))
            start = prev = n
    runs.append(f"{start}-{prev}" if prev > start else str(start))
    return ", ".join(runs)


def _find_duplicates(nums: list[int]) -> list[int]:
    """Return numbers that appear more than once."""
    seen: set[int] = set()
    dupes: set[int] = set()
    for n in nums:
        if n in seen:
            dupes.add(n)
        seen.add(n)
    return sorted(dupes)


def _find_gaps(nums: list[int]) -> list[int]:
    """Find missing integers in a sorted sequence."""
    if not nums:
        return []
    full = set(range(min(nums), max(nums) + 1))
    return sorted(full - set(nums))
