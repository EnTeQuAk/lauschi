"""Discover artist IDs across providers for catalog series."""

from __future__ import annotations

import click
from rich.console import Console
from rich.table import Table

from lauschi_catalog.catalog.discover_ops import (
    classify_match,
    discover_all,
    discover_candidates,
    discover_one,
    match_artist,
    prune_broken,
)
from lauschi_catalog.providers import Artist, CatalogProvider

console = Console()

# Re-export library functions so existing imports keep working.
__all__ = [
    "classify_match",
    "discover_candidates",
    "discover_for_provider",
    "match_artist",
]


def discover_for_provider(
    provider: CatalogProvider,
    series_title: str,
    *,
    verbose: bool = False,
) -> Artist | None:
    """Search a provider for the best matching artist."""
    candidates = provider.search_artists(series_title)

    if verbose and candidates:
        for c in candidates:
            console.print(
                f"  [{provider.name}] {c.name} ({c.id}) genres={c.genres}",
                style="dim",
            )

    return match_artist(series_title, candidates)


@click.command()
@click.argument("query", required=False)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--write", "-w", is_flag=True, help="Write discovered IDs to series.yaml")
@click.option(
    "--prune-broken",
    is_flag=True,
    help="Check every existing artist_id and remove those returning 404 from the provider",
)
@click.option("--verbose", "-v", is_flag=True)
def discover(
    query: str | None,
    provider: str,
    write: bool,
    prune_broken: bool,
    verbose: bool,
):
    """Discover artist IDs for a series across providers.

    If QUERY is given, searches for that series. Without QUERY, scans all
    series in the catalog that are missing provider IDs. With
    ``--prune-broken`` (no QUERY), instead validates every existing
    artist_id and removes any that return 404 from its provider.
    """
    from lauschi_catalog.catalog.providers_init import init_providers

    result = init_providers(provider)
    for w in result.warnings:
        console.print(f"[yellow]{w}[/yellow]")
    providers = result.providers

    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)

    if query:
        if prune_broken:
            console.print("[red]--prune-broken cannot be combined with a QUERY[/red]")
            raise SystemExit(2)
        _cli_discover_single(query, providers, write=write)
    elif prune_broken:
        _cli_prune_broken(providers, write=write)
    else:
        _cli_discover_all(providers, write=write)


def _cli_discover_single(
    query: str,
    providers: list[CatalogProvider],
    *,
    write: bool = False,
) -> None:
    """CLI wrapper: discover one series, render Rich table."""
    result = discover_one(
        query, providers, write=write,
        on_progress=lambda msg: console.print(msg),
    )

    table = Table(title=f"Artist Discovery: {query}")
    table.add_column("Provider", style="cyan")
    table.add_column("Artist", style="green")
    table.add_column("ID", style="yellow")

    for pname, match in result.matches.items():
        if match:
            table.add_row(pname, match.artist_name, match.artist_id)
        else:
            table.add_row(pname, "", "[dim]not found[/dim]")

    console.print(table)

    if result.created_new:
        console.print(
            f"[green]Created new series (id: {result.new_series_id})[/green]"
        )
    elif result.written:
        console.print("[green]Updated series.yaml[/green]")
    elif not write:
        pass
    else:
        console.print("[dim]No new artist_ids to write.[/dim]")


def _cli_discover_all(
    providers: list[CatalogProvider],
    *,
    write: bool = False,
) -> None:
    """CLI wrapper: discover all missing IDs, render Rich table."""
    table = Table(title="Artist Discovery (missing IDs)")
    table.add_column("Series", style="cyan", max_width=25)
    for p in providers:
        table.add_column(p.name, style="green")

    def on_progress(msg: str) -> None:
        console.print(msg, style="dim")

    result = discover_all(
        providers, write=write, on_progress=on_progress,
    )

    console.print(f"\n[bold]{result.found_total} new IDs discovered[/bold]")

    if result.written:
        console.print(f"[green]Updated {result.written} entries in series.yaml[/green]")
    elif result.updates and not write:
        console.print("[dim]Dry run. Pass --write to update series.yaml.[/dim]")


def _cli_prune_broken(
    providers: list[CatalogProvider],
    *,
    write: bool = False,
) -> None:
    """CLI wrapper: prune broken IDs, render Rich table."""
    table = Table(title="Broken artist_id Audit")
    table.add_column("Series", style="cyan", max_width=30)
    table.add_column("Provider", style="yellow")
    table.add_column("Removed", style="red")
    table.add_column("Kept", style="green")

    def on_progress(msg: str) -> None:
        console.print(msg, style="dim")

    result = prune_broken(
        providers, write=write, on_progress=on_progress,
    )

    for sid, provider_updates in result.pruned_series.items():
        for pname, kept in provider_updates.items():
            table.add_row(sid, pname, "(removed)", ", ".join(kept) or "[dim](empty)[/dim]")

    console.print(table)
    console.print(
        f"\n[bold]Checked {result.checked} artist_ids; "
        f"{result.broken} broken across {len(result.pruned_series)} series[/bold]",
    )

    if result.written:
        console.print(f"[green]Updated {result.written} entries in series.yaml[/green]")
    elif result.pruned_series and not write:
        console.print("[dim]Dry run. Pass --write to update series.yaml.[/dim]")
