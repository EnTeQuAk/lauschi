"""Human review: list series needing attention and suggest next steps.

Provides a fast CLI view of what the pipeline flagged for human eyes,
with actionable commands.
"""

import click
from rich import box
from rich.console import Console
from rich.table import Table

from lauschi_catalog.catalog.io import iter_curations
from lauschi_catalog.catalog.lifecycle import CurationState

console = Console()


def _load_all() -> list[dict]:
    return [c for _, c in iter_curations()]


@click.command("review-human")
@click.option(
    "--status",
    "-s",
    multiple=True,
    help="Filter by status (escalated, approved, curated)",
)
@click.option(
    "--detail",
    "-d",
    is_flag=True,
    help="Show per-series detail (concerns, fact disagreements)",
)
def review_human(status: tuple[str, ...], detail: bool):
    """List series that need human attention.

    After a pipeline run, some series are escalated (audit found
    incoherent output) or flagged (audit approved but disagreed with
    some facts). This command shows them with the next action to take.

    Examples: catalog-review-human (all), -s escalated, -s flagged, -d
    """
    all_data = _load_all()
    if not all_data:
        console.print("[dim]No curation files found.[/dim]")
        return

    want = set(s.lower() for s in status) if status else {"escalated", "curated"}

    need_attention: list[dict] = []
    for d in all_data:
        sid = d.get("id", "?")
        title = d.get("title", sid)
        state = CurationState.from_curation(d)
        review = dict(d.get("review") or {})

        if not want or state.status in want:
            need_attention.append(
                {
                    "id": sid,
                    "title": title,
                    "status": state.status,
                    "raw_status": review.get("status", "curated"),
                    "review": review,
                    "facts": d.get("series_facts"),
                    "albums": d.get("albums", []),
                }
            )

    if not need_attention:
        console.print("[green]Nothing needs human attention.[/green]")
        return

    table = Table(
        box=box.SIMPLE, title=f"Series needing attention ({len(need_attention)})"
    )
    table.add_column("Status", width=12)
    table.add_column("Series", min_width=30)
    table.add_column("Action")

    for item in sorted(
        need_attention,
        key=lambda x: (
            x["status"] != "escalated",
            x["title"],
        ),
    ):
        sid = item["id"]
        st = item["status"]

        if st == "escalated":
            action = (
                f"mise run catalog-edit -- {sid} list\n"
                f"  then: mise run catalog-curate -- {sid} --force\n"
                f"  then: mise run catalog-audit -- {sid} --force"
            )
            style = "red"
        elif st == "curated":
            action = f"mise run catalog-audit -- {sid}"
            style = "dim"
        else:
            action = "(ready for apply)"
            style = "green"

        table.add_row(
            f"[{style}]{st}[/{style}]",
            f"{item['title']}\n[dim]{sid}[/dim]",
            action,
        )

        if detail:
            concerns = item["review"].get("concerns", [])
            if concerns:
                for c in concerns[:3]:
                    reason = c if isinstance(c, str) else c.get("reason", "")
                    table.add_row("", f"  [dim]Concern: {reason[:120]}[/dim]", "")
            facts = item.get("facts")
            if facts:
                for e in facts.get("era_boundaries", []):
                    if not e.get("audited_by"):
                        table.add_row(
                            "",
                            f"  [yellow]⚠ era '{e.get('label')}': unaudited[/yellow]",
                            "",
                        )
                for g in facts.get("known_gaps", []):
                    if not g.get("audited_by"):
                        table.add_row(
                            "",
                            f"  [yellow]⚠ gap {g.get('number')}: unaudited[/yellow]",
                            "",
                        )
                for s in facts.get("sub_series", []):
                    if not s.get("audited_by"):
                        table.add_row(
                            "",
                            f"  [yellow]⚠ sub-series '{s.get('label')}': unaudited[/yellow]",
                            "",
                        )

    console.print(table)
    console.print()
    console.print(
        "[dim]Tip: run with --detail (-d) to see per-series concerns and fact disagreements.[/dim]"
    )
