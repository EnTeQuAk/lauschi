"""Apply split proposals from AI review to curation files."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path

import click
from rich.console import Console

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

console = Console()


@click.command("apply-splits")
@click.argument("series_id", required=False)
@click.option("--apply", "do_apply", is_flag=True, help="Actually write changes (default: dry run)")
def apply_splits(series_id: str | None, do_apply: bool):
    """Apply split proposals from AI review.

    Reads review.splits from curation JSONs and creates new curation files
    for the split-off series. Dry run by default.
    """
    if series_id:
        paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        paths = sorted(CURATION_DIR.glob("*.json"))

    splits_found = 0
    for path in paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        review = data.get("review", {})
        splits = review.get("splits", [])
        if not splits:
            continue

        for split in splits:
            new_id = split["new_series_id"]
            new_title = split["new_series_title"]
            album_ids = set(split["album_ids"])
            splits_found += 1

            # Find albums to move
            moved = [a for a in data["albums"] if a["album_id"] in album_ids]
            remaining = [a for a in data["albums"] if a["album_id"] not in album_ids]

            console.print(
                f"[bold]{data.get('title')}[/bold] → split off "
                f"[cyan]{new_title}[/cyan] ({len(moved)} albums)",
            )

            if do_apply:
                # Create new curation
                new_data = {
                    "id": new_id,
                    "title": new_title,
                    "aliases": [],
                    "keywords": [],
                    "episode_pattern": data.get("episode_pattern"),
                    "provider_artist_ids": data.get("provider_artist_ids", {}),
                    "albums": moved,
                    "split_from": data.get("id"),
                    "split_at": datetime.now(UTC).isoformat(),
                }
                new_path = CURATION_DIR / f"{new_id}.json"
                new_path.write_text(json.dumps(new_data, indent=2, ensure_ascii=False))
                console.print(f"  [green]Created {new_path}[/green]")

                # Update original
                data["albums"] = remaining
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
                console.print(f"  [green]Updated {path}[/green]")

    if splits_found == 0:
        console.print("[dim]No split proposals found[/dim]")
    elif not do_apply:
        console.print(f"\n[dim]{splits_found} splits found. Pass --apply to write.[/dim]")
