"""Discover artist IDs across providers for catalog series."""

from __future__ import annotations

import click
from rich.console import Console
from rich.table import Table

from lauschi_catalog.providers import Artist, CatalogProvider

console = Console()


def match_artist(
    series_title: str,
    candidates: list[Artist],
) -> Artist | None:
    """Find the best matching artist for a series title.

    Prefers exact name match, then substring, then Hörspiel genre.
    """
    title_lower = series_title.lower()

    # Exact match
    for c in candidates:
        if c.name.lower() == title_lower:
            return c

    # Title contained in artist name or vice versa
    for c in candidates:
        name_lower = c.name.lower()
        if title_lower in name_lower or name_lower in title_lower:
            return c

    # Hörspiel/kids genre
    kids_genres = {"kinder", "hörspiel", "hörbuch", "children", "kids", "spoken"}
    for c in candidates:
        genre_str = " ".join(c.genres).lower()
        if any(g in genre_str for g in kids_genres):
            return c

    # Single candidate fallback
    if len(candidates) == 1:
        return candidates[0]

    return None


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
@click.option("--verbose", "-v", is_flag=True)
def discover(query: str | None, provider: str, write: bool, verbose: bool):
    """Discover artist IDs for a series across providers.

    If QUERY is given, searches for that series. Without QUERY, scans all
    series in the catalog that are missing provider IDs.
    """
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider())
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider())
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)

    if query:
        _discover_single(query, providers, verbose=verbose)
    else:
        _discover_all(providers, write=write, verbose=verbose)


def _discover_single(query: str, providers: list[CatalogProvider], *, verbose: bool):
    """Discover artist IDs for a single series."""
    table = Table(title=f"Artist Discovery: {query}")
    table.add_column("Provider", style="cyan")
    table.add_column("Artist", style="green")
    table.add_column("ID", style="yellow")

    for p in providers:
        artist = discover_for_provider(p, query, verbose=verbose)
        if artist:
            table.add_row(p.name, artist.name, artist.id)
        else:
            table.add_row(p.name, "", "[dim]not found[/dim]")

    console.print(table)


def _discover_all(
    providers: list[CatalogProvider],
    *,
    write: bool = False,
    verbose: bool,
):
    """Discover missing artist IDs for all catalog series."""
    from lauschi_catalog.catalog.loader import load_catalog, update_provider_ids

    entries = load_catalog()
    table = Table(title="Artist Discovery (missing IDs)")
    table.add_column("Series", style="cyan", max_width=25)
    for p in providers:
        table.add_column(p.name, style="green")

    # Collect updates: {series_id: {provider: [artist_ids]}}
    updates: dict[str, dict[str, list[str]]] = {}
    found_total = 0

    for entry in entries:
        row = [entry.title]
        any_missing = False

        for p in providers:
            existing = entry.artist_ids(p.name)
            if existing:
                row.append(f"[dim]{existing[0]}[/dim]")
            else:
                any_missing = True
                artist = discover_for_provider(p, entry.title, verbose=verbose)
                if artist:
                    row.append(f"[green]{artist.id}[/green]")
                    found_total += 1
                    updates.setdefault(entry.id, {})[p.name] = [artist.id]
                else:
                    row.append("[dim]-[/dim]")

        if any_missing:
            table.add_row(*row)

    console.print(table)
    console.print(f"\n[bold]{found_total} new IDs discovered[/bold]")

    if write and updates:
        count = update_provider_ids(updates=updates)
        console.print(f"[green]Updated {count} entries in series.yaml[/green]")
    elif updates:
        console.print("[dim]Dry run. Pass --write to update series.yaml.[/dim]")
