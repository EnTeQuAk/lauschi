"""Delete a series from the catalog.

Removes the entry from series.yaml and its curation JSON, and records
the deletion in assets/catalog/deleted.yaml so future `catalog-add`
runs can warn before re-introducing the same id.

Use this for series that turn out to have no streaming presence, are
duplicates of another id, or were AI hallucinations during onboarding.
"""

from __future__ import annotations

from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.deleted import is_deleted, record_deletion
from lauschi_catalog.catalog.loader import (
    REPO_ROOT,
    SERIES_YAML,
    load_raw,
    save_raw,
)

console = Console()

CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


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
    data = load_raw(SERIES_YAML)
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
    curation_path = CURATION_DIR / f"{series_id}.json"

    console.print(f"[bold]Will remove:[/bold]")
    console.print(f"  series.yaml entry  → id={series_id}, title={title!r}")
    if curation_path.exists():
        try:
            display = curation_path.relative_to(REPO_ROOT)
        except ValueError:
            display = curation_path
        console.print(f"  curation file       → {display}")
    else:
        console.print(f"  curation file       → [dim](none)[/dim]")
    console.print(f"  deleted.yaml entry  → id={series_id}, reason={reason!r}")

    if dry_run:
        console.print("\n[dim]Dry run; nothing written. Drop --dry-run to apply.[/dim]")
        return

    # Apply: remove entry from yaml
    data["series"] = [e for e in entries if e.get("id") != series_id]
    save_raw(data, SERIES_YAML)

    # Remove curation file if present
    if curation_path.exists():
        curation_path.unlink()

    # Append to deletion log
    record_deletion(series_id, title, reason)

    console.print(f"\n[green]Deleted {series_id!r} from the catalog.[/green]")
