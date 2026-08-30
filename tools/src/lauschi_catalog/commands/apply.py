"""Apply approved curations to series.yaml (CLI wrapper).

Thin CLI layer over catalog.apply_ops. All business logic lives in
the library module.
"""

import click
from rich.console import Console

from lauschi_catalog.catalog.apply_ops import apply_curations

console = Console()


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Apply all approved curations")
@click.option("--dry-run", is_flag=True, help="Don't write changes")
@click.option(
    "--force",
    is_flag=True,
    help="Skip the review gates: apply incomplete, stale or escalated curations",
)
def apply(
    series_id: str | None, run_all: bool, dry_run: bool, force: bool
):
    """Apply approved curations to series.yaml.

    Reads curation JSONs and writes the included album IDs into the
    providers section of series.yaml. Exits 1 when any applied series
    was refused by the review gates, or when a named series has no
    curation file (a typos name must not look like success).
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    result = apply_curations(
        series_id,
        run_all=run_all,
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

    refusals = [d for d in result.details if d.refused]
    if refusals:
        console.print(
            f"[red]{len(refusals)} series refused by the review gates "
            "(see above); fix them or use --force deliberately[/red]"
        )
        raise SystemExit(1)
