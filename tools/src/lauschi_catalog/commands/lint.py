"""Deterministic lint checks for curation correctness.

Runs after review, before verify. Uses series_facts (era_boundaries,
known_gaps, etc.) to catch structural invariants. The goal is to catch
known failure modes deterministically so verify can focus on genuinely
novel inconsistencies.

Lint rules are generic (apply to every Hörspiel series). Per-series
facts (discovered by curate, confirmed by verify/human) guide the
checks so they don't fire false positives on documented quirks.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.facts import SeriesFacts

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def lint_curation(curation: dict) -> list[str]:
    """Run deterministic checks on a curation.

    Returns a list of human-readable issue strings. Empty list means
    no issues found. These issues are NOT escalations — they are
    warnings surfaced in the pipeline output for human review.
    """
    issues: list[str] = []
    albums = curation.get("albums", [])
    facts_dict = curation.get("series_facts")
    facts = (
        SeriesFacts.model_validate(facts_dict)
        if facts_dict else None
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
                f"[{prov}] Unexpected gaps at episodes: {unknown[:10]}"
                f"{'…' if len(unknown) > 10 else ''}"
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
        from lauschi_catalog.catalog.matcher import extract_episode

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
    # Episode on one provider but not the other, with no exclude_reason
    all_providers = sorted({a.get("provider", "?") for a in albums})
    if len(all_providers) > 1:
        for ep in set().union(*[set(eps) for eps in eps_by_provider.values()]):
            present = {prov for prov, eps in eps_by_provider.items() if ep in eps}
            missing = set(all_providers) - present
            if missing and len(present) >= 1:
                # Check if the missing provider has this episode excluded
                for prov in missing:
                    exc = excluded_eps.get(prov, {})
                    if ep not in exc:
                        issues.append(
                            f"Episode {ep} on {', '.join(sorted(present))} "
                            f"but missing from {prov} (not even excluded)"
                        )
                    elif not exc[ep].get("exclude_reason"):
                        issues.append(
                            f"Episode {ep} on {', '.join(sorted(present))} "
                            f"but excluded on {prov} without reason"
                        )

    # ── Rule 6: Unconfirmed facts ────────────────────────────────────
    if facts:
        for e in facts.era_boundaries:
            if e.verify_status == "disagreed":
                issues.append(
                    f"Unconfirmed era_boundary '{e.label}': {e.verify_reasoning}"
                )
        for g in facts.known_gaps:
            if g.verify_status == "disagreed":
                issues.append(
                    f"Unconfirmed known_gap ep {g.number}: {g.verify_reasoning}"
                )
        for s in facts.sub_series:
            if s.verify_status == "disagreed":
                issues.append(
                    f"Unconfirmed sub_series '{s.label}': {s.verify_reasoning}"
                )

    return issues


def _year(release_date: str) -> int:
    """Extract year from ISO date or YYYY string."""
    if not release_date:
        return 0
    try:
        return int(release_date[:4])
    except ValueError:
        return 0


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
