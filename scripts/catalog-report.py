#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.0", "requests", "rich"]
# ///
"""
catalog-report.py — Analyze all curations and report issues.

Outputs a structured report of gaps, duplicates, suspicious exclusions, etc.

Usage
-----
  mise run catalog-report              # all series
  mise run catalog-report -- fuenf_freunde  # single series
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from rich import box
from rich.console import Console
from rich.table import Table

REPO_ROOT = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

console = Console()


def _safe_int(s: str | None) -> int | None:
    if not s:
        return None
    try:
        return int(s)
    except ValueError:
        return None


def load_series(path: Path) -> dict:
    raw = json.loads(path.read_text())
    return raw.get("series", raw)


def analyze(series_id: str, series: dict) -> dict[str, Any]:
    """Return a dict of issues found."""
    albums = series.get("albums", [])
    included = [a for a in albums if a.get("include")]
    excluded = [a for a in albums if not a.get("include")]
    pattern = series.get("episode_pattern")

    issues: dict[str, Any] = {"id": series_id, "title": series.get("title", series_id)}

    # Episode numbering analysis
    eps = sorted(a.get("episode_num") for a in included if a.get("episode_num") is not None)
    if eps:
        expected = set(range(min(eps), max(eps) + 1))
        gaps = sorted(expected - set(eps))
        if gaps:
            issues["gaps"] = gaps

        # Duplicates: same episode_num appearing multiple times
        from collections import Counter
        counts = Counter(a.get("episode_num") for a in included if a.get("episode_num") is not None)
        dupes = {ep: n for ep, n in counts.items() if n > 1}
        if dupes:
            dupe_details = []
            for ep in sorted(dupes):
                entries = [a for a in included if a.get("episode_num") == ep]
                dupe_details.append({
                    "episode": ep,
                    "count": dupes[ep],
                    "albums": [{"id": a["spotify_album_id"], "title": a["title"]} for a in entries],
                })
            issues["duplicates"] = dupe_details

    # No episodes at all
    if not included:
        issues["empty"] = True

    # No artist IDs
    if not series.get("spotify_artist_ids"):
        issues["no_artist"] = True

    # Suspicious exclusions: albums that look like regular episodes
    if pattern:
        try:
            pat = re.compile(pattern)
            suspicious = []
            for a in excluded:
                m = pat.search(a.get("title", ""))
                if m:
                    reason = a.get("exclude_reason", "")
                    # Skip if the reason is clearly valid
                    if any(kw in reason.lower() for kw in ["box", "compil", "best of", "jubiläum", "kopfhörer"]):
                        continue
                    suspicious.append({
                        "id": a["spotify_album_id"],
                        "title": a["title"],
                        "episode": _safe_int(m.group(1)) if m.groups() else None,
                        "reason": reason,
                    })
            if suspicious:
                issues["suspicious_exclusions"] = suspicious
        except re.error:
            pass

    return issues


def print_report(issues_list: list[dict]) -> None:
    # Summary table
    t = Table(title="Curation Issues", box=box.SIMPLE)
    t.add_column("Series", width=30)
    t.add_column("Gaps", width=8)
    t.add_column("Duplicates", width=12)
    t.add_column("Suspicious", width=12)
    t.add_column("Notes", width=40)

    problem_count = 0
    for issues in issues_list:
        if len(issues) <= 2:  # only id + title = no issues
            continue
        problem_count += 1
        gaps = issues.get("gaps", [])
        dupes = issues.get("duplicates", [])
        suspicious = issues.get("suspicious_exclusions", [])
        notes = []
        if issues.get("empty"):
            notes.append("EMPTY (stub)")
        if issues.get("no_artist"):
            notes.append("no artist ID")

        t.add_row(
            issues["title"],
            str(len(gaps)) if gaps else "",
            str(len(dupes)) if dupes else "",
            str(len(suspicious)) if suspicious else "",
            ", ".join(notes) if notes else "",
        )

    console.print(t)
    console.print(f"\n{problem_count} series with issues\n")

    # Details for each
    for issues in issues_list:
        if len(issues) <= 2:
            continue
        console.print(f"\n[bold]━━━ {issues['title']} ({issues['id']}) ━━━[/]")

        if issues.get("gaps"):
            console.print(f"  [yellow]Gaps ({len(issues['gaps'])}): {issues['gaps'][:30]}[/]")

        if issues.get("duplicates"):
            for d in issues["duplicates"]:
                console.print(f"  [red]Duplicate episode {d['episode']}:[/]")
                for a in d["albums"]:
                    console.print(f"    • {a['title']}  [dim]{a['id']}[/]")

        if issues.get("suspicious_exclusions"):
            console.print(f"  [cyan]Suspicious exclusions ({len(issues['suspicious_exclusions'])}):[/]")
            for s in issues["suspicious_exclusions"][:10]:
                ep = f"ep {s['episode']}" if s.get("episode") else ""
                console.print(f"    • {s['title']}  {ep}  [dim]reason: {s['reason'][:50]}[/]")
            if len(issues["suspicious_exclusions"]) > 10:
                console.print(f"    … and {len(issues['suspicious_exclusions']) - 10} more")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("series_id", nargs="?", help="Analyze a single series")
    ap.add_argument("--json", action="store_true", help="Output as JSON")
    args = ap.parse_args()

    if args.series_id:
        paths = [CURATION_DIR / f"{args.series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    issues_list = []
    for p in paths:
        if not p.exists():
            console.print(f"[red]Not found: {p}[/]")
            continue
        raw = json.loads(p.read_text())
        # Skip rejected stubs
        if raw.get("review", {}).get("status") == "rejected":
            continue
        series = raw.get("series", raw)
        issues = analyze(p.stem, series)
        issues_list.append(issues)

    if args.json:
        # Only output series with issues
        with_issues = [i for i in issues_list if len(i) > 2]
        print(json.dumps(with_issues, indent=2, ensure_ascii=False))
    else:
        print_report(issues_list)


if __name__ == "__main__":
    main()
