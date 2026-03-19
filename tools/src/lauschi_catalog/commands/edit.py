"""CLI for editing curation files (add/remove/toggle albums)."""

from __future__ import annotations

import json
from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.matcher import extract_episode

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

console = Console()


def _load(series_id: str) -> tuple[Path, dict]:
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Not found: {path}[/red]")
        raise SystemExit(1)
    return path, json.loads(path.read_text())


def _save(path: Path, data: dict):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    console.print(f"[green]Saved {path}[/green]")


@click.group()
def edit():
    """Edit curation files."""


@edit.command()
@click.argument("series_id")
@click.argument("album_id")
@click.option("--provider", "-p", default="spotify")
def exclude(series_id: str, album_id: str, provider: str):
    """Exclude an album from a curation."""
    path, data = _load(series_id)
    for a in data["albums"]:
        if a["album_id"] == album_id and a.get("provider", "spotify") == provider:
            a["include"] = False
            a["exclude_reason"] = "manual exclusion"
            console.print(f"Excluded: {a['title']}")
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
            console.print(f"Included: {a['title']}")
            _save(path, data)
            return
    console.print(f"[yellow]Album {album_id} not found in {series_id}[/yellow]")


@edit.command("list")
@click.argument("series_id")
@click.option("--excluded", is_flag=True, help="Show excluded albums only")
def list_albums(series_id: str, excluded: bool):
    """List albums in a curation."""
    _, data = _load(series_id)
    albums = data.get("albums", [])
    if excluded:
        albums = [a for a in albums if not a.get("include")]

    for a in sorted(albums, key=lambda x: (x.get("episode_num") or 999, x["title"])):
        status = "✓" if a.get("include") else "✗"
        ep = a.get("episode_num") or "?"
        prov = a.get("provider", "spotify")[:2]
        console.print(f"  {status} {ep:>3}  [{prov}] {a['title']}")

    console.print(f"\n{len(albums)} albums")
