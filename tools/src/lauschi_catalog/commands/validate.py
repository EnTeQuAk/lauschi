"""Catalog validation across providers (CLI wrapper).

Thin CLI layer over catalog.validate_ops. All business logic lives in
the library module.
"""

from __future__ import annotations

import click
from rich.console import Console
from rich.markup import escape
from rich.table import Table

from lauschi_catalog.catalog.providers_init import init_providers
from lauschi_catalog.catalog.validate_ops import validate_catalog

console = Console()


@click.command()
@click.option(
    "--provider",
    "-p",
    type=click.Choice(["spotify", "apple_music", "all"]),
    default="all",
)
@click.option("--series", "-s", help="Filter to series whose title contains this")
@click.option("--verbose", "-v", is_flag=True)
def validate(provider: str, series: str | None, verbose: bool):
    """Validate catalog against provider APIs.

    Runs L1 (syntax) always. L5 (artist discography) for providers with
    artist IDs configured.
    """
    result = init_providers(provider, use_cache=False)
    for w in result.warnings:
        console.print(f"[yellow]{w}[/yellow]")
    providers = result.providers

    vresult = validate_catalog(
        providers,
        series_filter=series,
        on_progress=lambda msg: console.print(msg, markup=False),
    )

    exit_code = 0
    if vresult.l1_issues:
        console.print("[red]L1 SYNTAX issues:[/red]")
        for issue in vresult.l1_issues:
            console.print(f"  {issue}")
        exit_code = 1
    else:
        console.print("[green]L1 SYNTAX: no issues[/green]")

    if not providers:
        if exit_code:
            raise click.ClickException("Validation failed")
        return

    table = Table(title="L5 Artist Discography Validation")
    table.add_column("Series", style="cyan", max_width=25)
    table.add_column("Pattern", style="dim", max_width=25)
    for p in providers:
        table.add_column(f"{p.name} rate", justify="right")

    for sv in vresult.series_results:
        pattern_str = escape(str(sv.pattern or "-")[:25])
        row = [escape(sv.title), pattern_str]

        for p in providers:
            l5 = sv.l5_results.get(p.name)
            if l5 is None:
                row.append("[dim]-[/dim]")
                continue
            cell: list[str] = []
            if l5.total > 0:
                prefix = "ids:" if l5.album_check else ""
                if l5.is_perfect:
                    cell.append(f"[green]{prefix}{l5.matched}/{l5.total}[/green]")
                elif l5.unmatched:
                    cell.append(f"[red]{prefix}{l5.matched}/{l5.total}[/red]")
                    exit_code = 1
                else:
                    cell.append(f"[yellow]{prefix}{l5.matched}/{l5.total}[/yellow]")
                if l5.unverified:
                    cell.append(f"[yellow]?{len(l5.unverified)}[/yellow]")
            if l5.has_pattern and l5.pattern_total > 0:
                if l5.pattern_rate > 0.7:
                    cell.append(
                        f"[green]pat:{l5.pattern_matched}/{l5.pattern_total}[/green]"
                    )
                elif l5.pattern_rate > 0.4:
                    cell.append(
                        f"[yellow]pat:{l5.pattern_matched}/{l5.pattern_total}[/yellow]"
                    )
                else:
                    cell.append(
                        f"[red]pat:{l5.pattern_matched}/{l5.pattern_total}[/red]"
                    )
            if not cell:
                row.append("[dim]-[/dim]")
            else:
                row.append(" ".join(cell))

            if verbose and l5.unmatched:
                for t in l5.unmatched[:3]:
                    console.print(f"    [{p.name}] x {t}", style="dim")
            if verbose and l5.pattern_unmatched:
                for t in l5.pattern_unmatched[:3]:
                    console.print(f"    [{p.name}] pattern x {t}", style="dim")

        table.add_row(*row)

    console.print(table)

    for p in providers:
        count = vresult.tested.get(p.name, 0)
        if count > 0:
            console.print(
                f"[bold]{p.name}:[/bold] {vresult.perfect.get(p.name, 0)}/{count} "
                f"series with perfect match rate"
            )

    if exit_code:
        raise click.ClickException("Validation failed")
