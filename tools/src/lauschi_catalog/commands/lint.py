"""Deterministic lint checks for curation correctness.

Runs standalone, as part of the pipeline, and as a tool inside the
curate finalize agent for self-correction. Uses series_facts
(era_boundaries, known_gaps, etc.) to catch structural invariants.

Lint rules are generic (apply to every Hörspiel series). Per-series
facts (discovered by curate, audited by a second model) guide the
checks so they don't fire false positives on documented quirks.
"""

from __future__ import annotations

import json

import click
from rich.console import Console

from lauschi_catalog.catalog.facts import SeriesFacts
from lauschi_catalog.catalog.matcher import extract_episode
from lauschi_catalog.catalog.paths import CURATION_DIR

console = Console()


def lint_curation(curation: dict) -> list[str]:
    """Run deterministic checks on a curation.

    Returns a list of human-readable issue strings. Empty list means
    no issues found. These issues are NOT escalations — they are
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
            issues.append(
                f"[malformed series_facts: {type(e).__name__}: {e}]"
            )
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
        for prov in eps_by_provider:
            for era in facts.era_boundaries:
                # Parse year range like "1976-1979" or "2025-"
                rng = era.release_date_range
                if "-" not in rng:
                    continue
                parts = rng.split("-")
                start_y = int(parts[0].strip())
                end_y = int(parts[1].strip()) if parts[1].strip() else 9999
                era_eps = [
                    ep for ep in eps_by_provider[prov]
                    if _year(
                        next(
                            (a.get("release_date", "") for a in eps_albums_by_provider[prov].get(ep, [])),
                            "",
                        ),
                    ) in range(start_y, end_y + 1)
                ]
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
                issues.append(
                    f"[{prov}] Duplicate episode numbers: {dupes}"
                )

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
            issues.append(
                f"[{prov}] Unexpected gaps at episodes: {unknown}"
            )

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
                # prev is not in the curation at all — that's a gap (Rule 2)
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
            1 for a in included if extract_episode(pattern, a.get("title", "")) is not None
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
                key = (",".join(sorted(present)), prov, reason_type,
                )
                asym.setdefault(key, []).append(ep)

        for (present_key, prov, reason_type), eps in sorted(asym.items()):
            eps_str = _compress_runs(sorted(eps))
            issues.append(
                f"Episodes {eps_str} on {present_key} but {reason_type} "
                f"on {prov}"
            )

    # ── Rule 6: Unaudited facts ─────────────────────────────────────
    if facts:
        for e in facts.era_boundaries:
            if not e.audited_by:
                issues.append(
                    f"Unaudited era_boundary '{e.label}'"
                )
        for g in facts.known_gaps:
            if not g.audited_by:
                issues.append(
                    f"Unaudited known_gap ep {g.number}"
                )
        for s in facts.sub_series:
            if not s.audited_by:
                issues.append(
                    f"Unaudited sub_series '{s.label}'"
                )

    # ── Rule 7: Low-confidence clusters ──────────────────────────────
    low_conf = [
        a for a in albums
        if a.get("confidence") in ("medium", "low")
    ]
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
    auto_included = [
        a for a in albums
        if "auto-included" in (a.get("notes") or "")
    ]
    if auto_included:
        titles = [a.get("title", "?") for a in auto_included[:5]]
        suffix = f" (and {len(auto_included) - 5} more)" if len(auto_included) > 5 else ""
        issues.append(
            f"[auto_included] {len(auto_included)} album(s) were auto-included "
            f"because the agent omitted them: {', '.join(titles)}{suffix}"
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


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Lint all curated series")
def lint(series_id: str | None, run_all: bool):
    """Run deterministic lint checks on curation output."""
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    total = 0
    with_issues = 0
    clean = 0

    for path in paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        sid = data.get("id", path.stem)
        title = data.get("title", sid)
        issues = lint_curation(data)
        total += 1
        if issues:
            with_issues += 1
            console.print(f"[yellow]{title}[/yellow] ({sid})")
            for issue in issues:
                console.print(f"  • {issue}")
        else:
            clean += 1

    console.print(
        f"\n[bold]Results:[/bold] {clean} clean, "
        f"{with_issues} with issues (of {total} checked)",
    )
