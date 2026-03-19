"""Apply approved curations to series.yaml.

Reads curation JSONs with status 'approved', extracts album IDs
per provider, and writes them into the providers section of series.yaml.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
from rich.console import Console

from lauschi_catalog.catalog.loader import SERIES_YAML, load_raw, save_raw

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def _apply_one(series_id: str, data: dict, yaml_data: dict) -> bool:
    """Apply a single curation to the yaml data. Returns True if updated."""
    albums = data.get("albums", [])
    included = [a for a in albums if a.get("include")]

    if not included:
        console.print(f"  [dim]{series_id}: no included albums[/dim]")
        return False

    # Group by provider
    by_provider: dict[str, list[dict]] = {}
    for a in included:
        prov = a.get("provider", "spotify")
        by_provider.setdefault(prov, []).append(a)

    # Find the series entry in yaml
    yaml_series = None
    for entry in yaml_data.get("series", []):
        if entry.get("id") == series_id:
            yaml_series = entry
            break

    if yaml_series is None:
        console.print(f"  [yellow]{series_id}: not in series.yaml, skipping[/yellow]")
        return False

    if "providers" not in yaml_series:
        yaml_series["providers"] = {}

    updated = False

    for prov_name, prov_albums in by_provider.items():
        sorted_albums = sorted(
            prov_albums,
            key=lambda a: (a.get("episode_num") or 999_999, a.get("title", "")),
        )

        if prov_name not in yaml_series["providers"]:
            yaml_series["providers"][prov_name] = {}

        prov_section = yaml_series["providers"][prov_name]

        # Build the albums list
        album_entries = []
        for a in sorted_albums:
            entry: dict = {"id": a["album_id"]}
            if a.get("episode_num") is not None:
                entry["episode"] = a["episode_num"]
            entry["title"] = a["title"]
            album_entries.append(entry)

        # Only update if the new list is different (avoid no-op writes)
        existing = prov_section.get("albums", [])
        existing_ids = {e.get("id") for e in existing} if existing else set()
        new_ids = {e["id"] for e in album_entries}

        if new_ids != existing_ids:
            prov_section["albums"] = album_entries
            updated = True
            console.print(
                f"  {prov_name}: {len(album_entries)} albums "
                f"({len(new_ids - existing_ids)} new, "
                f"{len(existing_ids - new_ids)} removed)",
            )

    # Also update provider artist IDs from curation
    prov_artist_ids = data.get("provider_artist_ids", {})
    for prov_name, aids in prov_artist_ids.items():
        if aids and prov_name in yaml_series["providers"]:
            current = yaml_series["providers"][prov_name].get("artist_ids", [])
            if set(str(a) for a in aids) != set(str(a) for a in current):
                yaml_series["providers"][prov_name]["artist_ids"] = [
                    str(a) for a in aids
                ]
                updated = True

    # Update episode pattern if curation has one
    pattern = data.get("episode_pattern")
    if pattern and pattern != yaml_series.get("episode_pattern"):
        yaml_series["episode_pattern"] = pattern
        updated = True

    # Update keywords/aliases
    for field in ("keywords", "aliases"):
        val = data.get(field)
        if val and val != yaml_series.get(field):
            yaml_series[field] = val
            updated = True

    return updated


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Apply all approved curations")
@click.option("--status", default="approved", help="Only apply curations with this status")
@click.option("--dry-run", is_flag=True, help="Don't write changes")
def apply(series_id: str | None, run_all: bool, status: str, dry_run: bool):
    """Apply approved curations to series.yaml.

    Reads curation JSONs, extracts per-provider album IDs, and writes
    them into the providers section of series.yaml. Only processes
    curations with the specified status (default: approved).
    """
    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    yaml_data = load_raw()
    applied = 0
    skipped = 0

    for path in paths:
        if not path.exists():
            continue

        data = json.loads(path.read_text())
        sid = data.get("id", path.stem)

        # Check status
        review = data.get("review", {})
        cur_status = review.get("status", "curated")
        if cur_status != status and not series_id:
            skipped += 1
            continue

        console.print(f"[bold]{data.get('title', sid)}[/bold] (status: {cur_status})")

        if _apply_one(sid, data, yaml_data):
            applied += 1
        else:
            skipped += 1

    if applied > 0 and not dry_run:
        save_raw(yaml_data)
        console.print(f"\n[green]Applied {applied} curations to series.yaml[/green]")
    elif applied > 0:
        console.print(f"\n[dim]Dry run: {applied} would be applied[/dim]")
    else:
        console.print(f"\n[dim]Nothing to apply ({skipped} skipped)[/dim]")
