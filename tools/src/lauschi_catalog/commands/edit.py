"""CLI for editing curation files (add/remove/toggle albums)."""

import json
from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.canonical import album_sort_key
from lauschi_catalog.catalog.curate_ops import album_provenance
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.merge_ops import move_albums
from lauschi_catalog.catalog.paths import curation_path

console = Console()


def _load(series_id: str) -> tuple[Path, dict]:
    path = curation_path(series_id)
    if not path.exists():
        console.print(f"[red]Not found: {path}[/red]")
        raise SystemExit(1)
    return path, json.loads(path.read_text())


def _save(path: Path, data: dict):
    safe_write_json(path, data)
    console.print(f"[green]Saved {path}[/green]")


@click.group()
def edit():
    """Edit curation files."""


@edit.command()
@click.argument("series_id")
@click.argument("album_id")
@click.option("--provider", "-p", default="spotify")
@click.option(
    "--reason",
    "-r",
    required=True,
    help="Why this album is being excluded (recorded in the curation JSON)",
)
def exclude(series_id: str, album_id: str, provider: str, reason: str):
    """Exclude an album from a curation.

    Records the reason on the album, so a future review pass (or
    re-curation) can tell intentional drops from agent-generated ones.
    """
    path, data = _load(series_id)
    for a in data["albums"]:
        if a["album_id"] == album_id and a.get("provider", "spotify") == provider:
            a["include"] = False
            a["exclude_reason"] = reason
            a.update(album_provenance("operator"))
            console.print(f"Excluded: {a['title']}")
            console.print(f"  reason: {reason}")
            _save(path, data)
            return
    console.print(f"[yellow]Album {album_id} not found in {series_id}[/yellow]")


@edit.command()
@click.argument("series_id")
@click.argument("album_id")
@click.option("--provider", "-p", default="spotify")
def include(series_id: str, album_id: str, provider: str):
    """Include a previously excluded album."""
    path, data = _load(series_id)
    for a in data["albums"]:
        if a["album_id"] == album_id and a.get("provider", "spotify") == provider:
            a["include"] = True
            a.pop("exclude_reason", None)
            a.update(album_provenance("operator"))
            console.print(f"Included: {a['title']}")
            _save(path, data)
            return
    console.print(f"[yellow]Album {album_id} not found in {series_id}[/yellow]")


@edit.command()
@click.argument("source_id")
@click.argument("target_id")
@click.argument("albums", nargs=-1, required=True, metavar="PROVIDER:ALBUM_ID...")
def move(source_id: str, target_id: str, albums: tuple[str, ...]):
    """Move albums to another entry of the same family.

    The source keeps each album as sub_series_bleed with the target named
    as its owner. The target includes it, numbered by its own pattern.
    series.yaml changes with the next apply, source first.

    Example:

      lauschi-catalog edit move hexe_lilli hexe_lilli_erstlesergeschichten \\
          apple_music:1056441922 spotify:4ghoOGAttLAGG5LHZ2TyJI
    """
    keys: list[tuple[str, str]] = []
    for ref in albums:
        provider, sep, album_id = ref.partition(":")
        if not sep or not provider or not album_id:
            raise click.UsageError(f"{ref!r} is not provider:album_id")
        keys.append((provider, album_id))

    result = move_albums(source_id, target_id, keys)
    if not result.ok:
        console.print(f"[red]Nothing moved: {result.error}[/red]")
        raise SystemExit(1)
    console.print(
        f"[green]Moved {result.moved} album(s) from {source_id} to {target_id}[/green]"
    )
    console.print("Write series.yaml with, in this order:")
    console.print(f"  lauschi-catalog apply {source_id}")
    console.print(f"  lauschi-catalog apply {target_id}")


@edit.command("list")
@click.argument("series_id")
@click.option("--excluded", is_flag=True, help="Show excluded albums only")
def list_albums(series_id: str, excluded: bool):
    """List albums in a curation."""
    _, data = _load(series_id)
    albums = data.get("albums", [])
    if excluded:
        albums = [a for a in albums if not a.get("include")]

    for a in sorted(albums, key=album_sort_key):
        status = "✓" if a.get("include") else "✗"
        ep = a.get("episode_num") or "?"
        prov = a.get("provider", "spotify")[:2]
        console.print(f"  {status} {ep:>3}  [{prov}] {a['title']}")

    console.print(f"\n{len(albums)} albums")
