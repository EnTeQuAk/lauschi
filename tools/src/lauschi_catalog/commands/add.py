"""Add a new series to the catalog (CLI wrapper).

Interactive CLI layer over catalog.add_ops. Analysis, entry building,
and duplicate checks live in the library module. This module handles
provider search with user prompts.
"""

from __future__ import annotations

from io import StringIO

import click
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from ruamel.yaml import YAML

from lauschi_catalog.catalog.add_ops import (
    add_series,
    analyse_patterns,
    build_entry,
    title_to_id,
)
from lauschi_catalog.catalog.deleted import is_deleted
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.discover_ops import discover_for_provider, match_artist
from lauschi_catalog.providers import Album, Artist
from lauschi_catalog.providers.apple_music import AppleMusicProvider
from lauschi_catalog.providers.spotify import SpotifyProvider

console = Console()

# Re-export library functions so existing imports keep working.
__all__ = [
    "analyse_patterns",
    "build_entry",
    "title_to_id",
]


def print_analysis(artist: Artist, albums: list[Album], analysis: dict) -> None:
    """Print a summary of the discography analysis."""
    console.print(Panel(
        f"[bold]{artist.name}[/]  [dim]{artist.id}[/]\n"
        f"Followers: {artist.followers:,} · Albums: {analysis['total']}",
        title="Discography analysis",
    ))

    t = Table(box=box.SIMPLE, title="Episode patterns (first-match wins)")
    t.add_column("Pattern", min_width=12)
    t.add_column("Matches", justify="right", width=8)
    t.add_column("Coverage", justify="right", width=8)
    total = analysis["total"]
    for name, count in analysis["by_pattern"].items():
        pct = round(100 * count / total) if total else 0
        t.add_row(name, str(count), f"{pct}%")
    if analysis["unmatched"]:
        pct = round(100 * len(analysis["unmatched"]) / total) if total else 0
        t.add_row(
            "[dim]unmatched[/]", str(len(analysis["unmatched"])),
            f"{pct}%", style="dim",
        )
    console.print(t)

    if analysis["gaps"]:
        console.print(f"[yellow]Sequence gaps:[/] {analysis['gaps'][:20]}")

    if analysis["unmatched"]:
        console.print("\n[yellow]Unmatched titles:[/]")
        for u in analysis["unmatched"][:10]:
            console.print(f"  [dim]{u}[/]")

    if analysis["numbered"]:
        console.print("\n[bold]Titles sorted by episode number:[/]")
        for title, num in analysis["numbered"][:20]:
            console.print(f"  {num:>4}  {title}")
        if len(analysis["numbered"]) > 20:
            console.print(f"  [dim]... and {len(analysis['numbered']) - 20} more[/]")


@click.command()
@click.argument("title")
@click.option("--id", "series_id", default=None, help="Override auto-generated snake_case ID")
@click.option("--spotify-artist-id", default=None, help="Spotify artist ID (skips search)")
@click.option("--apple-music-artist-id", default=None, help="Apple Music artist ID (skips search)")
@click.option("--no-analyse", is_flag=True, help="Skip discography analysis (just create a minimal seed)")
@click.option("--dry-run", "-n", is_flag=True, help="Print the entry without writing")
@click.option(
    "--force-readd",
    is_flag=True,
    help="Re-introduce an id that was previously deleted (removes the deletion-log entry)",
)
def add(
    title: str,
    series_id: str | None,
    spotify_artist_id: str | None,
    apple_music_artist_id: str | None,
    no_analyse: bool,
    dry_run: bool,
    force_readd: bool,
):
    """Add a new series to the catalog.

    Searches providers for the artist, analyses the discography for episode
    patterns, and creates a seed entry in series.yaml.

    Examples:

      \b
      lauschi-catalog add "Senta"
      lauschi-catalog add "TKKG" --spotify-artist-id 7uVDfCKp96l3xCHFYf39vU
      lauschi-catalog add "Bibi Blocksberg" --dry-run
    """
    sid = series_id or title_to_id(title)
    existing_ids = {e.id for e in load_catalog()}
    if sid in existing_ids:
        console.print(f"[red]Series '{sid}' already exists in series.yaml[/red]")
        raise SystemExit(1)

    deletion = is_deleted(sid)
    if deletion and not force_readd:
        console.print(
            f"[red]Series '{sid}' was previously deleted "
            f"({deletion.get('deleted_at', '?')}).[/red]\n"
            f"[red]Reason on file: {deletion.get('reason', '(no reason recorded)')!r}[/red]\n"
            f"[yellow]Re-add anyway with --force-readd if you've reconsidered.[/yellow]",
        )
        raise SystemExit(1)

    # Resolve artists per provider (interactive)
    artists: dict[str, Artist] = {}

    spotify: SpotifyProvider | None = None
    try:
        spotify = SpotifyProvider()
    except SystemExit:
        console.print("[yellow]Spotify credentials not set, skipping[/yellow]")

    if spotify:
        if spotify_artist_id:
            artist = _fetch_artist_by_id(spotify, spotify_artist_id)
            if artist:
                artists["spotify"] = artist
        else:
            artist = _search_and_pick(spotify, title)
            if artist:
                artists["spotify"] = artist

    apple: AppleMusicProvider | None = None
    try:
        apple = AppleMusicProvider()
    except FileNotFoundError:
        console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if apple:
        if apple_music_artist_id:
            artists["apple_music"] = Artist(
                id=apple_music_artist_id,
                name=title,
                provider="apple_music",
            )
        else:
            found = discover_for_provider(apple, title)
            if found:
                artists["apple_music"] = found

    if not artists:
        console.print("[yellow]No providers found any matching artist.[/yellow]")
        if not click.confirm("Create entry without provider IDs?"):
            raise SystemExit(0)

    analysis = None
    if not no_analyse:
        for pname, artist in artists.items():
            provider = spotify if pname == "spotify" else apple
            if provider:
                console.print(f"\n[bold]Analysing {artist.name} discography ({pname})...[/bold]")
                albums = provider.artist_albums(artist.id)
                if albums:
                    analysis = analyse_patterns(albums)
                    print_analysis(artist, albums, analysis)
                    break

    entry = build_entry(
        title,
        series_id=series_id,
        artists=artists,
        analysis=analysis,
    )

    console.print()
    _print_entry(entry)

    if dry_run:
        console.print("\n[dim]Dry run, not writing.[/dim]")
        return

    result = add_series(
        title,
        series_id=series_id,
        artists=artists,
        analysis=analysis,
        force_readd=force_readd,
        on_progress=lambda msg: console.print(msg),
    )

    if not result.ok:
        console.print(f"[red]{result.error}[/red]")
        raise SystemExit(1)

    console.print(f"\n[green]Added '{result.series_id}' to series.yaml[/green]")


def _fetch_artist_by_id(provider: SpotifyProvider, artist_id: str) -> Artist | None:
    """Fetch a Spotify artist by ID."""
    try:
        # Use the provider's internal _get to hit the artist endpoint
        data = provider._get(f"artists/{artist_id}")
        return Artist(
            id=data["id"],
            name=data["name"],
            provider="spotify",
            genres=data.get("genres", []),
            followers=data.get("followers", {}).get("total", 0),
        )
    except Exception as e:
        console.print(f"[red]Failed to fetch artist {artist_id}: {e}[/red]")
        return None


def _search_and_pick(provider: SpotifyProvider, query: str) -> Artist | None:
    """Search Spotify for artists and let the user pick."""
    candidates = provider.search_artists(query)
    if not candidates:
        console.print(f"[yellow]No Spotify artists found for '{query}'[/yellow]")
        return None

    if len(candidates) == 1:
        a = candidates[0]
        console.print(f"[green]Found:[/green] {a.name} ({a.id}) {a.followers:,} followers")
        return a

    # Use the same matching logic as discover
    auto = match_artist(query, candidates)

    console.print(f"\n[bold]Spotify artist candidates for '{query}':[/bold]")
    for i, c in enumerate(candidates):
        marker = " [green]← auto-matched[/green]" if c == auto else ""
        console.print(f"  {i}: {c.name} ({c.id}) {c.followers:,} followers{marker}")

    if auto:
        if click.confirm(f"\nUse '{auto.name}'?", default=True):
            return auto

    choice = click.prompt(
        "Pick a number (or 'skip')",
        default="skip",
    )
    if choice == "skip":
        return None
    try:
        return candidates[int(choice)]
    except (ValueError, IndexError):
        console.print("[red]Invalid choice[/red]")
        return None


def _print_entry(entry: dict) -> None:
    """Pretty-print a series entry."""
    y = YAML()
    y.default_flow_style = False
    buf = StringIO()
    y.dump([entry], buf)
    yaml_text = buf.getvalue()

    console.print(Panel(yaml_text.strip(), title="New series entry", border_style="green"))
