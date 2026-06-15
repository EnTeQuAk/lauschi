"""Apply split proposals from AI review to curation files."""

from __future__ import annotations

import json

import click
from rich.console import Console

from lauschi_catalog.catalog.merge_ops import accept_split, normalize_album_ids
from lauschi_catalog.catalog.paths import CURATION_DIR

console = Console()


def _find_sub_index(path, label: str) -> int | None:
    """Find the current index of a sub_series by label (re-reads file)."""
    data = json.loads(path.read_text())
    subs = data.get("series_facts", {}).get("sub_series", [])
    for i, s in enumerate(subs):
        if s.get("label") == label:
            return i
    return None


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
        file_paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        file_paths = sorted(CURATION_DIR.glob("*.json"))

    splits_found = 0
    for path in file_paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        subs = data.get("series_facts", {}).get("sub_series", [])
        if not subs:
            continue

        parent_id = data.get("id", path.stem)
        parent_title = data.get("title", parent_id)
        albums = data.get("albums", [])
        all_album_ids = {a.get("album_id", "") for a in albums}

        labels_to_apply: list[str] = []
        for sub in subs:
            label = sub.get("label", "")
            album_ids = normalize_album_ids(sub.get("album_ids", []), all_album_ids)
            if not album_ids:
                continue
            splits_found += 1
            labels_to_apply.append(label)

            new_title = f"{parent_title}: {label.replace('_', ' ').title()}"
            console.print(
                f"[bold]{parent_title}[/bold] → split off "
                f"[cyan]{new_title}[/cyan] ({len(album_ids)} albums)",
            )

        if do_apply:
            for label in labels_to_apply:
                idx = _find_sub_index(path, label)
                if idx is None:
                    continue
                result = accept_split(parent_id, idx)
                if result.ok:
                    console.print(f"  [green]Created {result.new_id}[/green]")
                else:
                    console.print(f"  [red]Failed ({label}): {result.error}[/red]")

    if splits_found == 0:
        console.print("[dim]No sub_series with album_ids found[/dim]")
    elif not do_apply:
        console.print(
            f"\n[dim]{splits_found} splits found. Pass --apply to write.[/dim]",
        )
