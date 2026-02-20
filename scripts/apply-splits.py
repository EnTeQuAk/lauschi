#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "rich",
# ]
# ///
"""
apply-splits.py — Execute split proposals from AI review.

For each curation JSON that has review.splits, this script:
1. Creates a new curation JSON for each split series
2. Moves the split albums from the parent into the new JSON
3. Adds exclude overrides to the parent for the split albums

Run after review-series.py and before approving in the TUI.

Usage
-----
  mise exec -- uv run scripts/apply-splits.py          # dry-run (default)
  mise exec -- uv run scripts/apply-splits.py --apply   # actually write files
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from rich.console import Console
from rich.panel import Panel

console = Console()

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def process_splits(dry_run: bool) -> None:
    created = 0
    skipped = 0

    for path in sorted(CURATION_DIR.glob("*.json")):
        data = json.loads(path.read_text())
        review = data.get("review", {})
        splits = review.get("splits", [])
        if not splits:
            continue

        series = data.get("series", {})
        parent_id = series.get("id", path.stem)
        parent_title = series.get("title", parent_id)
        albums_by_id = {a["spotify_album_id"]: a for a in series.get("albums", [])}

        for split in splits:
            new_id = split["new_id"]
            new_title = split["new_title"]
            split_album_ids = set(split["album_ids"])
            reason = split.get("reason", "")
            new_path = CURATION_DIR / f"{new_id}.json"

            if new_path.exists():
                console.print(f"  [dim]Skip {new_id} — already exists[/]")
                skipped += 1
                continue

            # Collect albums for the new series
            split_albums = []
            missing = []
            for aid in split_album_ids:
                if aid in albums_by_id:
                    album = dict(albums_by_id[aid])
                    album["include"] = True
                    album["exclude_reason"] = None
                    split_albums.append(album)
                else:
                    missing.append(aid)

            if missing:
                console.print(f"  [yellow]Warning: {len(missing)} album IDs "
                              f"not found in {parent_id}[/]")

            # Build the new curation JSON
            new_data = {
                "query": f"Split from {parent_id}",
                "model": "review-series.py",
                "curated_at": datetime.now(tz=UTC).isoformat(),
                "series": {
                    "id": new_id,
                    "title": new_title,
                    "aliases": [],
                    "keywords": [],
                    # Inherit artist IDs from parent
                    "spotify_artist_ids": series.get("spotify_artist_ids", []),
                    "episode_pattern": series.get("episode_pattern"),
                    "albums": split_albums,
                    "age_note": series.get("age_note"),
                    "curator_notes": f"Split from {parent_title}. {reason}",
                },
                "review": {
                    "status": "pending",
                    "overrides": [],
                    "notes": f"Auto-created by apply-splits.py from {parent_id}.",
                },
            }

            lines = [
                f"✂️  **{parent_title}** → **{new_title}**",
                f"   `{parent_id}` → `{new_id}`",
                f"   {len(split_albums)} albums moved",
            ]
            if reason:
                lines.append(f"   {reason[:120]}")

            console.print(Panel(
                "\n".join(lines),
                border_style="cyan" if dry_run else "green",
                title="[dry-run]" if dry_run else "✅ created",
            ))

            if not dry_run:
                new_path.write_text(json.dumps(new_data, indent=2, ensure_ascii=False))

                # Add exclude overrides to parent for split albums
                parent_overrides = {o["album_id"]: o
                                    for o in review.get("overrides", [])}
                for aid in split_album_ids:
                    if aid not in parent_overrides:
                        parent_overrides[aid] = {
                            "album_id": aid,
                            "action": "exclude",
                            "reason": f"Split to {new_id}",
                        }
                review["overrides"] = list(parent_overrides.values())
                data["review"] = review
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False))

            created += 1

    if created == 0 and skipped == 0:
        console.print("[dim]No splits to process.[/]")
    else:
        verb = "Would create" if dry_run else "Created"
        console.print(f"\n{verb} {created} new series. Skipped {skipped}.")
        if dry_run:
            console.print("[dim]Run with --apply to write files.[/]")


def main() -> None:
    ap = argparse.ArgumentParser(description="Execute split proposals from AI review.")
    ap.add_argument("--apply", action="store_true",
                    help="Actually write files (default is dry-run)")
    args = ap.parse_args()
    process_splits(dry_run=not args.apply)


if __name__ == "__main__":
    main()
