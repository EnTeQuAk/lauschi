"""Print the audit status of a curation for shell pipelines."""

import click
from rich.console import Console

from lauschi_catalog.catalog.io import load_curation
from lauschi_catalog.catalog.lifecycle import CurationState
from lauschi_catalog.catalog.paths import curation_path

console = Console()


@click.command(name="audit-status")
@click.argument("series_id")
def audit_status(series_id: str) -> None:
    """Print the review status of a curation (curated/approved/escalated).

    Exit 0 approved, exit 1 escalated or missing: catalog-pipeline uses
    this to stop before applying unaudited work.
    """
    path = curation_path(series_id)
    if not path.exists():
        console.print(f"[red]No curation file for {series_id}[/red]")
        raise SystemExit(1)

    state = CurationState.from_curation(load_curation(series_id))
    console.print(state.status)
    if state.status != "approved":
        raise SystemExit(1)
