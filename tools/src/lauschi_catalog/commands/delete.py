"""Delete a series from the catalog.

Removes the entry from series.yaml and its curation JSON, and records
the deletion in assets/catalog/deleted.yaml so future `catalog-add`
runs can warn before re-introducing the same id.

Use this for series that turn out to have no streaming presence, are
duplicates of another id, or were AI hallucinations during onboarding.
"""

from __future__ import annotations

import click
from rich.console import Console

from lauschi_catalog.catalog import paths
from lauschi_catalog.catalog.deleted import is_deleted
from lauschi_catalog.catalog.loader import load_raw

console = Console()


@click.command()
@click.argument("series_id")
@click.option(
    "--reason",
    "-r",
    required=True,
    help="Why this series is being removed (logged for future runs)",
)
@click.option(
    "--dry-run",
    "-n",
    is_flag=True,
    help="Show what would change without writing",
)
def delete(series_id: str, reason: str, dry_run: bool):
    """Delete SERIES_ID from the catalog.

    Removes the entry from series.yaml, deletes the matching curation
    JSON if any, and records the deletion in deleted.yaml so future
    catalog-add runs warn before re-introducing the same id.

    Example:

      lauschi-catalog delete tom_turbo --reason "No streaming presence"
    """
    yaml_path = paths.series_yaml_path()
    data = load_raw(yaml_path)
    entries = data.get("series") or []
    target = next((e for e in entries if e.get("id") == series_id), None)
    if target is None:
        console.print(f"[red]Series {series_id!r} not found in series.yaml[/red]")
        raise SystemExit(1)

    already = is_deleted(series_id)
    if already:
        console.print(
            f"[yellow]Note: {series_id!r} is already in deleted.yaml "
            f"(reason: {already.get('reason')!r}). "
            f"Refreshing the log entry.[/yellow]",
        )

    title = target.get("title", series_id)
    curation_file = paths.curation_path(series_id)
    repo_root = paths.repo_root()

    console.print("[bold]Will remove:[/bold]")
    console.print(f"  series.yaml entry  → id={series_id}, title={title!r}")
    if curation_file.exists():
        try:
            display = curation_file.relative_to(repo_root)
        except ValueError:
            display = curation_file
        console.print(f"  curation file       → {display}")
    else:
        console.print("  curation file       → [dim](none)[/dim]")
    console.print(f"  deleted.yaml entry  → id={series_id}, reason={reason!r}")

    if dry_run:
        console.print("\n[dim]Dry run; nothing written. Drop --dry-run to apply.[/dim]")
        return

    from lauschi_catalog.catalog.series_ops import delete_series

    result = delete_series(series_id, reason=reason)
    if not result.ok:
        console.print(f"[red]{result.error}[/red]")
        raise SystemExit(1)

    console.print(f"\n[green]Deleted {series_id!r} from the catalog.[/green]")
