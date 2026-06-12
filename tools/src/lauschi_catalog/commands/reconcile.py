"""CLI command for cross-provider reconciliation."""

from __future__ import annotations

import json

import click
from rich.console import Console

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.catalog.reconcile import (
    normalize_exclude_reason,
    reconcile_cross_provider,
)

console = Console()


@click.command()
@click.option("-s", "--series", "series_id", help="Single series to reconcile")
@click.option("--all", "run_all", is_flag=True, help="Reconcile all curations")
@click.option(
    "--normalize", is_flag=True, help="Also normalize verbose exclude_reasons"
)
@click.option("--dry-run", is_flag=True, help="Report changes without writing")
def reconcile(series_id: str | None, run_all: bool, normalize: bool, dry_run: bool):
    """Fix cross-provider mismatches in curation decisions.

    Auto-flips wrong_content_type/music_single mismatches where the
    same title is included on the other provider. Flags compilation
    and sub_series_bleed mismatches for human review.
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    total_flipped = 0
    total_flagged = 0
    total_normalized = 0

    for path in paths:
        if not path.exists():
            continue

        data = json.loads(path.read_text())
        albums = data.get("albums", [])
        sid = data.get("id", path.stem)
        changed = False

        if normalize:
            for a in albums:
                if not a.get("include"):
                    old = a.get("exclude_reason")
                    new = normalize_exclude_reason(old)
                    if old != new:
                        a["exclude_reason"] = new
                        total_normalized += 1
                        changed = True

        result = reconcile_cross_provider(albums)

        if result.flipped > 0 or result.flagged > 0:
            console.print(f"\n[bold]{data.get('title', sid)}[/bold]")
            for d in result.details:
                if d["action"] == "flipped":
                    console.print(
                        f"  [green]FLIP[/green] {d['provider']}: "
                        f"{d['title']!r} ({d['old_reason']} -> include)"
                    )
                else:
                    console.print(
                        f"  [yellow]FLAG[/yellow] {d['provider']}: "
                        f"{d['title']!r} ({d['reason']})"
                    )

        total_flipped += result.flipped
        total_flagged += result.flagged

        if (result.flipped > 0 or changed) and not dry_run:
            safe_write_json(path, data)

    console.print("\n[bold]Summary:[/bold]")
    console.print(f"  Flipped (auto-fixed): {total_flipped}")
    console.print(f"  Flagged (needs review): {total_flagged}")
    if normalize:
        console.print(f"  Reasons normalized: {total_normalized}")
    if dry_run:
        console.print("  [dim](dry run, nothing written)[/dim]")
