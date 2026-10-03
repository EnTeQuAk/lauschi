"""CLI command for cross-provider reconciliation."""

import json

import click
from rich.console import Console

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import curation_dir, curation_path
from lauschi_catalog.catalog.reconcile import (
    drop_stale_known_gaps,
    normalized_reason,
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

    Flips an exclusion to include when the same title is included on
    the other provider and the reason is one that proves wrong
    (compilation, wrong_content_type, no reason, ...). Every other
    mismatch stays as it is; `lint` reports it as [title_counterpart].
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [curation_path(series_id)]
    else:
        paths = sorted(curation_dir().glob("*.json"))

    total_flipped = 0
    total_normalized = 0
    total_gaps_dropped = 0

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
                    new = normalized_reason(a)
                    if old != new:
                        a["exclude_reason"] = new
                        total_normalized += 1
                        changed = True
            dropped = drop_stale_known_gaps(data)
            if dropped:
                total_gaps_dropped += dropped
                changed = True
                console.print(
                    f"  [dim]{sid}: {dropped} stale known_gap(s) dropped[/dim]"
                )

        result = reconcile_cross_provider(albums)

        if result.flipped > 0:
            console.print(f"\n[bold]{data.get('title', sid)}[/bold]")
            for d in result.details:
                console.print(
                    f"  [green]FLIP[/green] {d['provider']}: "
                    f"{d['title']!r} ({d['old_reason']} -> include)"
                )

        total_flipped += result.flipped

        if (result.flipped > 0 or changed) and not dry_run:
            safe_write_json(path, data)

    console.print("\n[bold]Summary:[/bold]")
    console.print(f"  Flipped (auto-fixed): {total_flipped}")
    if normalize:
        console.print(f"  Reasons normalized: {total_normalized}")
        console.print(f"  Stale known_gaps dropped: {total_gaps_dropped}")
    if dry_run:
        console.print("  [dim](dry run, nothing written)[/dim]")
