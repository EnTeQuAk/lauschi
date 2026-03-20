"""Catalog validation across providers.

L1  SYNTAX      required fields, regex compiles, unique IDs
L2  SEARCH      keyword hit-rate against provider album search
L3  PATTERN     episode extraction rate within matched albums
L4  DISCOVERY   probes common naming patterns, suggests improvements
L5  ARTIST      full discography via artist ID (per provider)
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

import click
from rich.console import Console
from rich.table import Table

from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.matcher import extract_episode
from lauschi_catalog.providers import Album, CatalogProvider

console = Console()


@dataclass
class ValidationResult:
    series_id: str
    title: str
    issues: list[str] = field(default_factory=list)
    l2_hit_rate: float = 0.0
    l3_match_rate: float = 0.0
    l5_coverage: dict[str, float] = field(default_factory=dict)


def _validate_l1(entries) -> list[str]:
    """L1: syntax checks."""
    issues = []
    ids_seen = set()
    for e in entries:
        if not e.id:
            issues.append(f"Entry missing id: {e.title}")
        if e.id in ids_seen:
            issues.append(f"Duplicate id: {e.id}")
        ids_seen.add(e.id)
        if e.episode_pattern:
            patterns = [e.episode_pattern] if isinstance(e.episode_pattern, str) else e.episode_pattern
            for p in patterns:
                try:
                    re.compile(p)
                except re.error as err:
                    issues.append(f"{e.id}: bad pattern {p!r}: {err}")
    return issues


def _validate_l5(entry, provider: CatalogProvider) -> tuple[int, int, list[str]]:
    """L5: full discography validation via artist ID.

    Returns (matched, total, unmatched_titles).
    """
    aids = entry.artist_ids(provider.name)
    if not aids:
        return 0, 0, []

    all_albums: list[Album] = []
    for aid in aids:
        try:
            all_albums.extend(provider.artist_albums(aid))
        except Exception:
            # Artist may have been removed from provider
            continue

    if not all_albums:
        return 0, 0, []

    pattern = entry.effective_pattern(provider.name)
    matched = 0
    unmatched = []

    for album in all_albums:
        ep = extract_episode(pattern, album.name)
        if ep is not None:
            matched += 1
        else:
            unmatched.append(album.name)

    return matched, len(all_albums), unmatched


@click.command()
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--series", "-s", help="Filter to series whose title contains this")
@click.option("--verbose", "-v", is_flag=True)
def validate(provider: str, series: str | None, verbose: bool):
    """Validate catalog against provider APIs.

    Runs L1 (syntax) always. L5 (artist discography) for providers with
    artist IDs configured.
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

    entries = load_catalog()
    if series:
        q = series.lower()
        entries = [e for e in entries if q in e.title.lower() or q in e.id]

    # L1: syntax
    l1_issues = _validate_l1(entries)
    if l1_issues:
        console.print("[red]L1 SYNTAX issues:[/red]")
        for issue in l1_issues:
            console.print(f"  {issue}")
    else:
        console.print(f"[green]L1 SYNTAX: {len(entries)} series, no issues[/green]")

    if not providers:
        return

    # L5: artist discography match rates
    table = Table(title="L5 Artist Discography Validation")
    table.add_column("Series", style="cyan", max_width=25)
    table.add_column("Pattern", style="dim", max_width=25)
    for p in providers:
        table.add_column(f"{p.name} rate", justify="right")

    perfect = {p.name: 0 for p in providers}
    tested = {p.name: 0 for p in providers}

    for entry in entries:
        has_any = any(entry.artist_ids(p.name) for p in providers)
        if not has_any:
            continue

        from rich.markup import escape
        pattern_str = escape(str(entry.episode_pattern or "-")[:25])
        row = [escape(entry.title), pattern_str]

        for p in providers:
            aids = entry.artist_ids(p.name)
            if not aids:
                row.append("[dim]-[/dim]")
                continue

            matched, total, unmatched = _validate_l5(entry, p)
            tested[p.name] += 1

            if total == 0:
                row.append("[dim]0 albums[/dim]")
            elif matched == total:
                row.append(f"[green]{matched}/{total}[/green]")
                perfect[p.name] += 1
            elif matched > total * 0.7:
                row.append(f"[yellow]{matched}/{total}[/yellow]")
            else:
                row.append(f"[red]{matched}/{total}[/red]")

            if verbose and unmatched:
                for t in unmatched[:3]:
                    console.print(f"    [{p.name}] ✗ {t}", style="dim")

        table.add_row(*row)

    console.print(table)

    for p in providers:
        if tested[p.name] > 0:
            console.print(
                f"[bold]{p.name}:[/bold] {perfect[p.name]}/{tested[p.name]} "
                f"series with perfect match rate"
            )
