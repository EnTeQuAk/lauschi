"""Catalog report: analyze curations and show statistics."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path

import click
from rich import box
from rich.console import Console
from rich.table import Table

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

console = Console()


@click.command()
@click.argument("series_id", required=False)
def report(series_id: str | None):
    """Analyze curations and report statistics."""
    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    if not paths:
        console.print("[yellow]No curation files found[/yellow]")
        return

    table = Table(title="Catalog Report", box=box.SIMPLE)
    table.add_column("Series", style="cyan", max_width=25)
    table.add_column("Included", justify="right")
    table.add_column("Excluded", justify="right")
    table.add_column("Providers", style="dim")
    table.add_column("Gaps", justify="right")
    table.add_column("Pattern", style="dim", max_width=20)

    total_included = 0
    total_excluded = 0

    for path in paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        albums = data.get("albums", [])
        included = [a for a in albums if a.get("include")]
        excluded = [a for a in albums if not a.get("include")]

        providers = Counter(a.get("provider", "spotify") for a in included)
        provider_str = ", ".join(f"{k}:{v}" for k, v in sorted(providers.items()))

        # Find gaps
        nums = sorted(a["episode_num"] for a in included if a.get("episode_num"))
        gap_count = 0
        if nums:
            gap_count = sum(1 for i in range(nums[0], nums[-1] + 1) if i not in nums)

        pattern = data.get("episode_pattern")
        if isinstance(pattern, list):
            pattern = pattern[0][:20] + "…" if pattern else "-"
        elif pattern:
            pattern = pattern[:20]
        else:
            pattern = "-"

        table.add_row(
            data.get("title", path.stem),
            str(len(included)),
            str(len(excluded)),
            provider_str,
            str(gap_count) if gap_count else "-",
            pattern,
        )

        total_included += len(included)
        total_excluded += len(excluded)

    console.print(table)
    console.print(
        f"\n[bold]Total:[/bold] {len(paths)} series, "
        f"{total_included} included, {total_excluded} excluded",
    )
