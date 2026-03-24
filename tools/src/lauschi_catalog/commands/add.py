"""Add a new series to the catalog.

Creates a seed entry in series.yaml with title, keywords, episode_pattern,
and provider artist IDs. The rest of the pipeline (curate, review, apply,
validate) handles album-level curation.

Ported from the old scripts/discover-titles.py --ai workflow.
"""

from __future__ import annotations

import re
from collections import Counter

import click
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box

from lauschi_catalog.catalog.loader import load_catalog, load_raw, save_raw, SERIES_YAML
from lauschi_catalog.providers import Album, Artist, CatalogProvider

console = Console()

# Known episode-number prefixes in DACH Hörspiele, in priority order.
_PATTERNS: list[tuple[str, str]] = [
    ("NNN/", r"^(\d{1,3})/"),
    ("N:", r"^(\d{1,2}):\s"),
    ("Folge N", r"[Ff]olge\s+(\d+)"),
    ("Teil N", r"[Tt]eil\s+(\d+)"),
    ("Episode N", r"[Ee]pisode\s+(\d+)"),
    ("Fall N", r"[Ff]all\s+(\d+)"),
    ("Band N", r"[Bb]and\s+(\d+)"),
    ("Hörspiel N", r"[Hh]örspiel\s+(\d+)"),
    ("Nr. N", r"[Nn]r\\.?\\s+(\\d+)"),
]


def title_to_id(title: str) -> str:
    """Convert a series title to a snake_case ASCII identifier.

    Handles German umlauts explicitly (ä->ae, ö->oe, ü->ue, ß->ss)
    rather than stripping them via NFKD decomposition, which produces
    better IDs for German titles.
    """
    s = title.lower()
    for src, dst in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")]:
        s = s.replace(src, dst)
    # Replace non-alphanum with underscore, collapse runs, strip edges
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_")


def _which_pattern(title: str) -> tuple[str, str] | None:
    """Return the (name, regex) of the first matching pattern, or None."""
    for name, pat in _PATTERNS:
        if re.search(pat, title):
            return name, pat
    return None


def analyse_patterns(albums: list[Album]) -> dict:
    """Analyze album titles for episode numbering patterns.

    Returns a dict with pattern distribution, dominant pattern regex,
    and gap analysis.
    """
    titles = [a.name for a in albums]

    # For each title, which (first-matching) pattern fires?
    pattern_of: dict[str, tuple[str, str]] = {}  # title -> (name, regex)
    for t in titles:
        match = _which_pattern(t)
        if match:
            pattern_of[t] = match

    by_pattern: Counter[str] = Counter(name for name, _ in pattern_of.values())

    # Dominant pattern (most matches)
    dominant_name = by_pattern.most_common(1)[0][0] if by_pattern else None
    dominant_regex: str | None = None
    if dominant_name:
        for name, pat in _PATTERNS:
            if name == dominant_name:
                dominant_regex = pat
                break

    # Extract episode numbers using dominant pattern
    numbered: list[tuple[str, int]] = []
    if dominant_regex:
        for t in titles:
            m = re.search(dominant_regex, t)
            if m:
                try:
                    numbered.append((t, int(m.group(1))))
                except (ValueError, IndexError):
                    pass
    numbered.sort(key=lambda x: x[1])

    # Gap analysis
    nums = [n for _, n in numbered]
    if nums:
        full_range = set(range(min(nums), max(nums) + 1))
        gaps = sorted(full_range - set(nums))
    else:
        gaps = []

    return {
        "total": len(titles),
        "by_pattern": dict(by_pattern.most_common()),
        "unmatched": [t for t in titles if t not in pattern_of],
        "numbered": numbered,
        "gaps": gaps,
        "dominant_name": dominant_name,
        "dominant_regex": dominant_regex,
    }


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


def build_entry(
    title: str,
    *,
    series_id: str | None = None,
    artists: dict[str, Artist],
    analysis: dict | None = None,
    keywords: list[str] | None = None,
) -> dict:
    """Build a series.yaml entry dict (ruamel-compatible plain dict).

    Args:
        title: Series title.
        series_id: Override for the auto-generated ID.
        artists: {provider_name: Artist} from discovery.
        analysis: Pattern analysis from analyse_patterns(), if available.
        keywords: Override keywords. Defaults to [title].
    """
    sid = series_id or title_to_id(title)

    entry: dict = {
        "id": sid,
        "title": title,
        "keywords": keywords or [title],
    }

    # Episode pattern from analysis
    if analysis and analysis.get("dominant_regex"):
        entry["episode_pattern"] = analysis["dominant_regex"]

    # Provider artist IDs
    if artists:
        providers: dict = {}
        for pname, artist in sorted(artists.items()):
            providers[pname] = {"artist_ids": [artist.id]}
        entry["providers"] = providers

    return entry


def append_to_yaml(entry: dict) -> None:
    """Append a new series entry to series.yaml, preserving formatting."""
    data = load_raw()
    data["series"].append(entry)
    save_raw(data)


@click.command()
@click.argument("title")
@click.option("--id", "series_id", default=None, help="Override auto-generated snake_case ID")
@click.option("--spotify-artist-id", default=None, help="Spotify artist ID (skips search)")
@click.option("--apple-music-artist-id", default=None, help="Apple Music artist ID (skips search)")
@click.option("--keyword", "-k", multiple=True, help="Keywords (repeatable). Defaults to title.")
@click.option("--no-analyse", is_flag=True, help="Skip discography analysis (just create a minimal seed)")
@click.option("--dry-run", "-n", is_flag=True, help="Print the entry without writing")
def add(
    title: str,
    series_id: str | None,
    spotify_artist_id: str | None,
    apple_music_artist_id: str | None,
    keyword: tuple[str, ...],
    no_analyse: bool,
    dry_run: bool,
):
    """Add a new series to the catalog.

    Searches providers for the artist, analyses the discography for episode
    patterns, and creates a seed entry in series.yaml.

    Examples:

      \b
      lauschi-catalog add "Senta"
      lauschi-catalog add "TKKG" --spotify-artist-id 7uVDfCKp96l3xCHFYf39vU
      lauschi-catalog add "Bibi Blocksberg" -k "Bibi Blocksberg" --dry-run
    """
    from lauschi_catalog.providers.spotify import SpotifyProvider
    from lauschi_catalog.providers.apple_music import AppleMusicProvider

    # Check for duplicate
    sid = series_id or title_to_id(title)
    existing = load_catalog()
    existing_ids = {e.id for e in existing}
    if sid in existing_ids:
        console.print(f"[red]Series '{sid}' already exists in series.yaml[/red]")
        raise SystemExit(1)

    # Resolve artists per provider
    artists: dict[str, Artist] = {}

    # Spotify
    spotify: SpotifyProvider | None = None
    try:
        spotify = SpotifyProvider()
    except SystemExit:
        console.print("[yellow]Spotify credentials not set, skipping[/yellow]")

    if spotify:
        if spotify_artist_id:
            # Fetch artist info for the given ID
            artist = _fetch_artist_by_id(spotify, spotify_artist_id)
            if artist:
                artists["spotify"] = artist
        else:
            artist = _search_and_pick(spotify, title)
            if artist:
                artists["spotify"] = artist

    # Apple Music
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
            from lauschi_catalog.commands.discover import discover_for_provider
            found = discover_for_provider(apple, title, verbose=True)
            if found:
                artists["apple_music"] = found

    if not artists:
        console.print("[yellow]No providers found any matching artist.[/yellow]")
        if not click.confirm("Create entry without provider IDs?"):
            raise SystemExit(0)

    # Analyse discography for episode patterns
    analysis = None
    if not no_analyse:
        # Use first available provider that has albums
        for pname, artist in artists.items():
            provider = spotify if pname == "spotify" else apple
            if provider:
                console.print(f"\n[bold]Analysing {artist.name} discography ({pname})...[/bold]")
                albums = provider.artist_albums(artist.id)
                if albums:
                    analysis = analyse_patterns(albums)
                    print_analysis(artist, albums, analysis)
                    break

    # Build and write
    entry = build_entry(
        title,
        series_id=series_id,
        artists=artists,
        analysis=analysis,
        keywords=list(keyword) if keyword else None,
    )

    # Preview
    console.print()
    _print_entry(entry)

    if dry_run:
        console.print("\n[dim]Dry run, not writing.[/dim]")
        return

    append_to_yaml(entry)
    console.print(f"\n[green]Added '{entry['id']}' to series.yaml[/green]")
    console.print("[dim]Next steps: catalog-discover (fill missing IDs) → catalog-curate → catalog-review → catalog-apply → catalog-validate[/dim]")


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
    from lauschi_catalog.commands.discover import match_artist
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
    from ruamel.yaml import YAML
    from io import StringIO

    y = YAML()
    y.default_flow_style = False
    buf = StringIO()
    y.dump([entry], buf)
    yaml_text = buf.getvalue()

    console.print(Panel(yaml_text.strip(), title="New series entry", border_style="green"))
