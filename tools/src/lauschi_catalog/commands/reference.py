"""Look a series up in the public line index."""

import click
from rich import box
from rich.console import Console
from rich.table import Table

from lauschi_catalog.reference import ReferenceIndex

console = Console()


@click.command()
@click.argument("query")
@click.option("--all", "show_all", is_flag=True, help="Show every matching series")
def reference(query: str, show_all: bool):
    """Show how the public line index organises a series: its lines and
    their numbered episodes."""
    index = ReferenceIndex()
    if not index.configured:
        console.print(
            "[yellow]REFERENCE_INDEX_URL is not set (see .env.example)[/yellow]"
        )
        raise SystemExit(1)
    hits = index.find(query)
    if not hits:
        console.print(f"[yellow]No series matching {query!r} in the index[/yellow]")
        raise SystemExit(1)
    for sid, _name in hits if show_all else hits[:1]:
        series = index.series(sid)
        console.print(f"[bold]{series.name}[/bold] (index id {series.id})")
        for line in series.lines:
            table = Table(title=f"{line.name} ({len(line.episodes)})", box=box.SIMPLE)
            table.add_column("#", justify="right")
            table.add_column("Title")
            table.add_column("Min", justify="right")
            for e in line.episodes:
                table.add_row(
                    e.number or "", e.title, str(e.seconds // 60) if e.seconds else ""
                )
            console.print(table)
    if len(hits) > 1 and not show_all:
        others = ", ".join(name for _, name in hits[1:6])
        console.print(
            f"[dim]{len(hits) - 1} more match(es): {others} (--all shows them)[/dim]"
        )
