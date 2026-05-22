"""CLI wrapper for deterministic lint checks on curation output."""

from __future__ import annotations

import json

import click
from rich.console import Console

from lauschi_catalog.catalog.lint_ops import lint_curation
from lauschi_catalog.catalog.paths import CURATION_DIR

console = Console()


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Lint all curated series")
def lint(series_id: str | None, run_all: bool):
    """Run deterministic lint checks on curation output."""
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    total = 0
    with_issues = 0
    clean = 0

    for path in paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        sid = data.get("id", path.stem)
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

    console.print(
        f"\n[bold]Results:[/bold] {clean} clean, "
        f"{with_issues} with issues (of {total} checked)",
    )
