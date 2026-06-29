"""Apply approved curations to series.yaml (CLI wrapper).

Thin CLI layer over catalog.apply_ops. All business logic lives in
the library module.
"""

from __future__ import annotations

import click
from rich.console import Console

from lauschi_catalog.catalog.apply_ops import apply_curations

console = Console()


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Apply all approved curations")
@click.option(
    "--status",
    default="approved,ai_verified",
    help="Only apply curations with this status (comma-separated)",
)
@click.option("--dry-run", is_flag=True, help="Don't write changes")
@click.option(
    "--force",
    is_flag=True,
    help="Skip the lifecycle staleness check (apply even if audit is stale)",
)
def apply(
    series_id: str | None, run_all: bool, status: str, dry_run: bool, force: bool
):
    """Apply approved curations to series.yaml.

    Reads curation JSONs, extracts per-provider album IDs, and writes
    them into the providers section of series.yaml. Only processes
    curations with the specified status (default: approved).
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    allowed_statuses = {s.strip() for s in status.split(",")}

    result = apply_curations(
        series_id,
        run_all=run_all,
        allowed_statuses=allowed_statuses,
        dry_run=dry_run,
        force=force,
        on_progress=lambda msg: console.print(msg, markup=False),
    )

    if result.applied > 0 and result.written:
        console.print(
            f"\n[green]Applied {result.applied} curations to series.yaml[/green]"
        )
    elif result.applied > 0 and dry_run:
        console.print(f"\n[dim]Dry run: {result.applied} would be applied[/dim]")
    elif result.applied == 0:
        console.print(f"\n[dim]Nothing to apply ({result.skipped} skipped)[/dim]")
