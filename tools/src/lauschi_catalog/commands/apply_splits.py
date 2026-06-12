"""Apply split proposals from AI review to curation files."""

from __future__ import annotations

import json
from datetime import UTC, datetime

import click
from rich.console import Console

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import CURATION_DIR

console = Console()


@click.command("apply-splits")
@click.argument("series_id", required=False)
@click.option(
    "--apply",
    "do_apply",
    is_flag=True,
    help="Actually write changes (default: dry run)",
)
def apply_splits(series_id: str | None, do_apply: bool):
    """Apply sub_series split proposals from curation.

    Reads series_facts.sub_series from curation JSONs and creates new
    curation files for the split-off series. Dry run by default.
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
        subs = data.get("series_facts", {}).get("sub_series", [])
        if not subs:
            continue

        parent_id = data.get("id", path.stem)
        parent_title = data.get("title", parent_id)

        for sub in subs:
            label = sub["label"]
            album_ids = set(sub.get("album_ids", []))
            if not album_ids:
                continue
            splits_found += 1

            new_id = f"{parent_id}_{label}"
            new_title = f"{parent_title}: {label.replace('_', ' ').title()}"

            def _matches(album: dict) -> bool:
                key = f"{album.get('provider')}:{album.get('album_id')}"
                return key in album_ids

            moved = [a for a in data["albums"] if _matches(a)]
            remaining = [a for a in data["albums"] if not _matches(a)]

            console.print(
                f"[bold]{parent_title}[/bold] → split off "
                f"[cyan]{new_title}[/cyan] ({len(moved)} albums)",
            )

            if do_apply:
                now = datetime.now(UTC).isoformat()
                new_data = {
                    "id": new_id,
                    "title": new_title,
                    "aliases": [],
                    "episode_pattern": data.get("episode_pattern"),
                    "provider_artist_ids": data.get("provider_artist_ids", {}),
                    "age_note": data.get("age_note", ""),
                    "curator_notes": (
                        f"Split from {parent_title}. "
                        f"Contains {len(moved)} albums from the '{label}' sub-series."
                    ),
                    "series_facts": {},
                    "albums": moved,
                    "content_type": data.get("content_type", "hoerspiel"),
                    "incomplete": False,
                    "incomplete_reason": "",
                    "split_from": parent_id,
                    "split_at": now,
                    "curated_at": now,
                }
                new_path = CURATION_DIR / f"{new_id}.json"
                safe_write_json(new_path, new_data)
                console.print(f"  [green]Created {new_path}[/green]")

                data["albums"] = remaining
                safe_write_json(path, data)
                console.print(f"  [green]Updated {path}[/green]")

    if splits_found == 0:
        console.print("[dim]No sub_series with album_ids found[/dim]")
    elif not do_apply:
        console.print(
            f"\n[dim]{splits_found} splits found. Pass --apply to write.[/dim]"
        )
