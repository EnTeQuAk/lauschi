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
        _discover_single(query, providers, write=write, verbose=verbose)
    elif prune_broken:
        _prune_broken_ids(providers, write=write, verbose=verbose)
    else:
        _discover_all(providers, write=write, verbose=verbose)


def _discover_single(
    query: str,
    providers: list[CatalogProvider],
    *,
    write: bool = False,
    verbose: bool,
):
    """Discover artist IDs for a single series.

    With ``--write``, looks up the series in the catalog by id or title
    and persists discovered artist IDs back to series.yaml.
    """
    table = Table(title=f"Artist Discovery: {query}")
    table.add_column("Provider", style="cyan")
    table.add_column("Artist", style="green")
    table.add_column("ID", style="yellow")

    discoveries: dict[str, Artist] = {}
    for p in providers:
        artist = discover_for_provider(p, query, verbose=verbose)
        if artist:
            table.add_row(p.name, artist.name, artist.id)
            discoveries[p.name] = artist
        else:
            table.add_row(p.name, "", "[dim]not found[/dim]")

    console.print(table)

    if write:
        from lauschi_catalog.catalog.loader import (
            load_catalog,
            load_raw,
            save_raw,
            SERIES_YAML,
        )

        # Find the matching catalog entry by id or title
        catalog = load_catalog()
        entry = None
        for e in catalog:
            if e.id == query or e.title == query:
                entry = e
                break

        raw = load_raw()

        if not entry:
            # Auto-create a new series entry
            from lauschi_catalog.commands.add import title_to_id
            from lauschi_catalog.catalog.series_ops import add_series_entry

            new_id = title_to_id(query)
            title = query
            for artist in discoveries.values():
                if artist.name:
                    title = artist.name
                    break

            new_entry: dict = {
                "id": new_id,
                "title": title,
                "providers": {},
            }
            for pname, artist in discoveries.items():
                new_entry["providers"][pname] = {"artist_ids": [artist.id]}

            add_result = add_series_entry(new_entry)
            if not add_result.ok:
                console.print(f"[red]{add_result.error}[/red]")
                raise SystemExit(1)
            console.print(
                f"[green]Created new series '{title}' (id: {new_id}) "
                f"with {len(discoveries)} provider(s)[/green]"
            )
            return

        updated = False
        for raw_entry in raw.get("series", []):
            if raw_entry.get("id") != entry.id:
                continue
            raw_providers = raw_entry.setdefault("providers", {})
            for pname, artist in discoveries.items():
                raw_cfg = raw_providers.setdefault(pname, {})
                existing = raw_cfg.get("artist_ids") or []
                if not existing and raw_cfg.get("artist_id"):
                    existing = [raw_cfg.pop("artist_id")]
                if artist.id not in existing:
                    existing.append(artist.id)
                    raw_cfg["artist_ids"] = existing
                    updated = True
                    console.print(
                        f"[green]Added {pname} artist_id {artist.id} to "
                        f"{entry.id}[/green]"
                    )
            break

        if updated:
            save_raw(raw)
            console.print(f"[green]Updated {SERIES_YAML}[/green]")
        else:
            console.print("[dim]No new artist_ids to write.[/dim]")


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


def _prune_broken_ids(
    providers: list[CatalogProvider],
    *,
    write: bool,
    verbose: bool,
):
    """Remove artist_ids that return 404 from their provider.

    Walks every catalog entry, calls ``provider.artist_exists`` on each
    existing artist_id, and collects the ones that 404. Reports a table
    and, with --write, persists the kept-only list back to series.yaml.

    A 404 means the provider doesn't recognise the id anymore (artist
    moved, was renamed, was a hallucination, or never existed). Other
    HTTP errors propagate so a transient outage isn't treated as
    "missing" and silently nuked.
    """
    from lauschi_catalog.catalog.loader import load_catalog, update_provider_ids

    entries = load_catalog()
    table = Table(title="Broken artist_id Audit")
    table.add_column("Series", style="cyan", max_width=30)
    table.add_column("Provider", style="yellow")
    table.add_column("Removed", style="red")
    table.add_column("Kept", style="green")

    updates: dict[str, dict[str, list[str]]] = {}
    broken_count = 0
    checked_count = 0

    for entry in entries:
        for p in providers:
            existing = entry.artist_ids(p.name)
            if not existing:
                continue
            kept: list[str] = []
            removed: list[str] = []
            for aid in existing:
                checked_count += 1
                try:
                    ok = p.artist_exists(aid)
                except Exception as e:
                    if verbose:
                        console.print(
                            f"  [red]error checking {entry.id}/{p.name}/{aid}: {e}[/red]",
                        )
                    # On non-404 errors keep the id — don't punish transient
                    # outages by removing real data.
                    kept.append(aid)
                    continue
                if ok:
                    kept.append(aid)
                else:
                    removed.append(aid)
                    broken_count += 1
            if removed:
                table.add_row(
                    entry.id,
                    p.name,
                    ", ".join(removed),
                    ", ".join(kept) or "[dim](empty)[/dim]",
                )
                updates.setdefault(entry.id, {})[p.name] = kept

    console.print(table)
    console.print(
        f"\n[bold]Checked {checked_count} artist_ids; "
        f"{broken_count} broken across {len(updates)} series[/bold]",
    )

    if not updates:
        return

    if write:
        count = update_provider_ids(updates=updates)
        console.print(f"[green]Updated {count} entries in series.yaml[/green]")
    else:
        console.print("[dim]Dry run. Pass --write to update series.yaml.[/dim]")
