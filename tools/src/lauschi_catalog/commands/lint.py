"""CLI wrapper for deterministic lint checks on curation output."""

from itertools import groupby

import click
from rich.console import Console

from lauschi_catalog.catalog.io import iter_curations
from lauschi_catalog.catalog.lint_ops import lint_curation, unclaimed_albums

console = Console()


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Lint all curated series")
def lint(series_id: str | None, run_all: bool):
    """Run deterministic lint checks on curation output."""
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    curations = [
        {**data, "id": data.get("id", stem)} for stem, data in iter_curations()
    ]

    total = 0
    with_issues = 0
    clean = 0

    for data in curations:
        sid = data["id"]
        if series_id and sid != series_id:
            continue
        title = data.get("title", sid)
        issues = lint_curation(data)
        total += 1
        if issues:
            with_issues += 1
            console.print(f"[yellow]{title}[/yellow] ({sid})")
            for issue in issues:
                console.print(f"  • {issue}")
        else:
            clean += 1

    unclaimed = [
        album
        for album in unclaimed_albums(curations)
        if not series_id or series_id in album.seen_by
    ]
    if unclaimed:
        console.print(
            f"\n[yellow]{len(unclaimed)} album(s) that every entry leaves to "
            "another line[/yellow], so no entry ships them:"
        )
        for seen_by, albums in groupby(unclaimed, key=lambda a: a.seen_by):
            console.print(f"  {', '.join(seen_by)}", highlight=False)
            for album in albums:
                console.print(
                    f"    • {album.title} ({album.provider}:{album.album_id})",
                    highlight=False,
                    markup=False,
                )

    console.print(
        f"\n[bold]Results:[/bold] {clean} clean, "
        f"{with_issues} with issues (of {total} checked)",
    )
