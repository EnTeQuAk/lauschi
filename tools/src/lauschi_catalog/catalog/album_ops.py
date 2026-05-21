"""Album-level curation operations."""

from __future__ import annotations

import json
from dataclasses import dataclass

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import curation_path


@dataclass
class AlbumResult:
    ok: bool
    error: str | None = None


def update_album_status(
    series_id: str,
    album_id: str,
    *,
    include: bool,
    exclude_reason: str | None = None,
) -> AlbumResult:
    """Toggle include/exclude for a single album in a curation JSON."""
    path = curation_path(series_id)
    if not path.exists():
        return AlbumResult(ok=False, error="curation not found")

    data = json.loads(path.read_text())
    for album in data.get("albums", []):
        if album.get("album_id") == album_id:
            album["include"] = include
            if include:
                album.pop("exclude_reason", None)
            elif exclude_reason:
                album["exclude_reason"] = exclude_reason
            safe_write_json(path, data)
            return AlbumResult(ok=True)

    return AlbumResult(ok=False, error="album not found")
