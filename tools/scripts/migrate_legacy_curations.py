"""One-shot: migrate legacy-schema curation JSONs to the modern shape.

Legacy shape: {query, model, curated_at, series: {id, title, ..., albums: [{spotify_album_id, ...}]}, review}
Modern shape: {id, title, ..., content_type, provider_artist_ids, albums: [{album_id, provider, ...}], review, curated_at}

Run from the repo root: ``uv run --directory tools python scripts/migrate_legacy_curations.py``
The script is idempotent — already-migrated files are left alone.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def is_legacy(data: dict) -> bool:
    """Legacy: top-level albums missing, nested series.albums present."""
    if data.get("albums"):
        return False
    return bool(data.get("series", {}).get("albums"))


def migrate(data: dict) -> dict:
    """Return the modern-shape equivalent of a legacy curation dict."""
    series = data["series"]
    legacy_review = data.get("review", {})

    # Convert spotify_artist_ids list to provider_artist_ids dict.
    provider_artist_ids: dict[str, list[str]] = {}
    if series.get("spotify_artist_ids"):
        provider_artist_ids["spotify"] = list(series["spotify_artist_ids"])

    # Rename album_id field; all legacy albums are spotify-sourced.
    new_albums = [
        {
            "album_id": a["spotify_album_id"],
            "provider": "spotify",
            "include": a.get("include", True),
            "episode_num": a.get("episode_num"),
            "title": a["title"],
            "exclude_reason": a.get("exclude_reason"),
        }
        for a in series.get("albums", [])
    ]

    # Backfill missing review fields so the modern read path doesn't crash.
    review_block = dict(legacy_review)
    review_block.setdefault("overrides", [])
    review_block.setdefault("splits", [])
    review_block.setdefault("added_albums", [])
    review_block.setdefault("notes", "")

    return {
        "id": series["id"],
        "title": series["title"],
        "content_type": "hoerspiel",
        "aliases": series.get("aliases", []),
        "keywords": series.get("keywords", []),
        "episode_pattern": series.get("episode_pattern"),
        "provider_artist_ids": provider_artist_ids,
        "age_note": series.get("age_note", ""),
        "curator_notes": series.get("curator_notes", ""),
        "curated_at": data.get("curated_at", ""),
        "albums": new_albums,
        "review": review_block,
    }


def main(dry_run: bool = False) -> int:
    paths = sorted(CURATION_DIR.glob("*.json"))
    legacy = []
    for p in paths:
        try:
            data = json.loads(p.read_text())
        except json.JSONDecodeError as e:
            print(f"SKIP {p.name}: {e}")
            continue
        if not is_legacy(data):
            continue
        legacy.append(p)
        if dry_run:
            print(f"DRY {p.name}: {len(data['series'].get('albums', []))} albums")
            continue
        new_data = migrate(data)
        p.write_text(json.dumps(new_data, indent=2, ensure_ascii=False))
        print(f"OK  {p.name}: {len(new_data['albums'])} albums migrated")

    print(f"\nlegacy curations: {len(legacy)}")
    return 0


if __name__ == "__main__":
    dry = "--dry-run" in sys.argv
    sys.exit(main(dry_run=dry))
