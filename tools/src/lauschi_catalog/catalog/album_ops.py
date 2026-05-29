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


_SENTINEL = object()


def update_album(
    series_id: str,
    album_id: str,
    *,
    include: bool | None = None,
    exclude_reason: str | None = None,
    episode_num: int | str | None = _SENTINEL,
    title: str | None = _SENTINEL,
) -> AlbumResult:
    """Update fields on a single album in a curation JSON.

    Only provided fields are written. ``_SENTINEL`` default means
    "not provided" so we can distinguish None (clear the field)
    from absent.
    """
    path = curation_path(series_id)
    if not path.exists():
        return AlbumResult(ok=False, error="curation not found")

    data = json.loads(path.read_text())
    for album in data.get("albums", []):
        if album.get("album_id") == album_id:
            if include is not None:
                album["include"] = include
                if include:
                    album.pop("exclude_reason", None)
                elif exclude_reason:
                    album["exclude_reason"] = exclude_reason
            elif exclude_reason is not None:
                album["exclude_reason"] = exclude_reason

            if episode_num is not _SENTINEL:
                album["episode_num"] = episode_num

            if title is not _SENTINEL:
                album["title"] = title

            safe_write_json(path, data)
            return AlbumResult(ok=True)

    return AlbumResult(ok=False, error="album not found")
