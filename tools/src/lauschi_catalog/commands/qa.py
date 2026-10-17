"""Reference index QA CLI wrapper over catalog.reference_qa."""

import asyncio
from collections import Counter
from datetime import datetime

import click
from rich.console import Console
from rich.table import Table

from lauschi_catalog.catalog.paths import log_dir
from lauschi_catalog.catalog.reference_qa import (
    DEFAULT_MODEL,
    run_reference_qa,
    write_report,
)

console = Console()


@click.command(name="qa")
@click.argument("series_ids", nargs=-1)
@click.option(
    "-m", "--model", default=DEFAULT_MODEL, help="Model that judges what stays open"
)
@click.option("-c", "--concurrency", default=3, help="Entries checked in parallel")
def qa(series_ids: tuple[str, ...], model: str, concurrency: int) -> None:
    """Check entries against the reference index (all mapped ones by default).

    A script pairs each entry's albums with its index lines, and a model
    judges what stays open, one run per entry. Read-only: writes a report
    to logs/catalog/ and changes nothing in the catalog.
    """
    results = asyncio.run(
        run_reference_qa(
            list(series_ids) or None,
            model_name=model,
            concurrency=concurrency,
            on_progress=console.print,
        )
    )
    path = log_dir() / f"qa-{datetime.now():%Y%m%d-%H%M%S}.json"
    write_report(results, path)

    table = Table(title="Reference index QA")
    for column in (
        "entry",
        "index",
        "matched",
        "should ship",
        "out of place",
        "numbers",
        "failed",
    ):
        table.add_column(column)
    for r in sorted(results, key=lambda r: r.entry_id):
        kinds = Counter(f.kind for f in r.findings)
        episodes = sum(len(line.episodes) for line in r.mapping.lines)
        table.add_row(
            r.entry_id,
            str(episodes),
            str(r.match.matched),
            str(kinds["should_ship"] or ""),
            str(kinds["out_of_place"] or ""),
            str(len(r.match.number_differs) + len(r.match.title_differs) or ""),
            "yes" if r.error else "",
        )
    console.print(table)
    console.print(f"Report: {path}")
