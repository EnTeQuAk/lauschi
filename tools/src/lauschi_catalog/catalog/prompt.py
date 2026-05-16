"""Shared prompt-formatting utilities for catalog agents.

Every pipeline phase (curate, review, verify, finalize) feeds album
metadata to an LLM through prompts. This module provides ONE canonical
formatter so the representation is unified across all phases.
"""

from __future__ import annotations


def format_album_xml(album: dict, *, include_tracks: bool = True) -> str:
    """Format a single album as XML-tagged metadata.

    The XML structure is designed to be unambiguous for LLM parsing:
    every field is explicitly tagged, and the hierarchy makes the
    relationship between album and tracks clear.

    Args:
        album: dict with keys matching the unified schema:
            provider, id, title, episode_num, release_date,
            album_type, total_tracks, duration_min, label, artist,
            tracks (list of {name, duration_ms, track_number}).
        include_tracks: whether to inline the track listing.

    Returns:
        XML string (no outer wrapping element).
    """
    lines: list[str] = []
    lines.append(
        f'<album provider="{album.get("provider", "?")}" '
        f'id="{album.get("id", "?")}">'
    )
    lines.append(f"  <title>{album.get('title', '')}</title>")
    ep = album.get("episode_num")
    if ep is not None:
        lines.append(f"  <episode_num>{ep}</episode_num>")
    rel = album.get("release_date")
    if rel:
        lines.append(f"  <release_date>{rel}</release_date>")
    album_type = album.get("album_type")
    if album_type:
        lines.append(f"  <type>{album_type}</type>")
    lines.append(f"  <tracks_count>{album.get('total_tracks', 0)}</tracks_count>")
    inc = album.get("include")
    if inc is not None:
        status = "included" if inc else "excluded"
        lines.append(f"  <status>{status}</status>")
    reason = album.get("exclude_reason")
    if reason:
        lines.append(f"  <exclude_reason>{reason}</exclude_reason>")
    dur = album.get("duration_min")
    if dur is not None:
        lines.append(f"  <duration_min>{dur}</duration_min>")
    label = album.get("label")
    if label:
        lines.append(f"  <label>{label}</label>")
    artist = album.get("artist")
    if artist:
        lines.append(f"  <artist>{artist}</artist>")

    tracks = album.get("tracks", [])
    if include_tracks and tracks:
        lines.append("  <tracks>")
        for t in tracks[:8]:
            dur_ms = t.get("duration_ms", 0)
            dur_s = f' duration_ms="{dur_ms}"' if dur_ms else ""
            num = t.get("track_number")
            num_attr = f' num="{num}"' if num else ""
            lines.append(
                f"    <track{num_attr}{dur_s}>{t.get('name', '')}</track>"
            )
        if len(tracks) > 8:
            lines.append(f"    <!-- {len(tracks) - 8} more tracks -->")
        lines.append("  </tracks>")
    lines.append("</album>")
    return "\n".join(lines)


def format_albums_xml(albums: list[dict], *, include_tracks: bool = True) -> str:
    """Format a list of albums as an XML document.

    Wraps each album in <albums>...</albums> so the LLM sees a single
    coherent document rather than a flat concatenation.
    """
    lines = ["<albums>"]
    for a in albums:
        lines.append(format_album_xml(a, include_tracks=include_tracks))
    lines.append("</albums>")
    return "\n".join(lines)


def album_to_dict(album_detail: object) -> dict:
    """Normalize a provider Album (or album_details dict) to the unified dict.

    Accepts:
        - lauschi_catalog.providers.Album
        - dict from seen_details cache
    """
    if isinstance(album_detail, dict):
        d = album_detail
        return {
            "provider": d.get("provider", "?"),
            "id": d.get("id", "?"),
            "title": d.get("name", d.get("title", "")),
            "episode_num": d.get("episode_num"),
            "release_date": d.get("release_date", ""),
            "album_type": d.get("album_type", ""),
            "total_tracks": d.get("total_tracks", 0),
            "duration_min": d.get("duration_min"),
            "label": d.get("label", ""),
            "artist": d.get("artists", ""),
            "tracks": [
                {
                    "name": t.get("name", ""),
                    "duration_ms": t.get("duration_ms", 0),
                    "track_number": t.get("track_number"),
                }
                for t in d.get("tracks", [])
            ],
        }

    # Provider Album dataclass
    from lauschi_catalog.providers import Album

    if isinstance(album_detail, Album):
        total_dur = sum(t.duration_ms for t in album_detail.tracks)
        dur_min = round(total_dur / 60000, 1) if total_dur else None
        return {
            "provider": album_detail.provider,
            "id": album_detail.id,
            "title": album_detail.name,
            "episode_num": None,
            "release_date": album_detail.release_date,
            "album_type": album_detail.album_type,
            "total_tracks": album_detail.total_tracks,
            "duration_min": dur_min,
            "label": album_detail.label,
            "artist": album_detail.artists,
            "tracks": [
                {
                    "name": t.name,
                    "duration_ms": t.duration_ms,
                    "track_number": None,
                }
                for t in album_detail.tracks
            ],
        }

    raise TypeError(f"Expected dict or Album, got {type(album_detail)}")


def curation_album_to_dict(a: dict) -> dict:
    """Normalize a curation JSON album dict to the unified schema.

    Curation albums use ``album_id`` instead of ``id`` and may carry
    ``include`` / ``exclude_reason`` from a prior curation pass.
    """
    return {
        "provider": a.get("provider", "?"),
        "id": a.get("album_id", a.get("id", "?")),
        "title": a.get("title", a.get("name", "")),
        "episode_num": a.get("episode_num"),
        "release_date": a.get("release_date", ""),
        "album_type": a.get("album_type", ""),
        "total_tracks": a.get("total_tracks", 0),
        "duration_min": a.get("duration_min"),
        "label": a.get("label", ""),
        "artist": a.get("artist", a.get("artists", "")),
        "include": a.get("include"),
        "exclude_reason": a.get("exclude_reason", ""),
        "tracks": [
            {
                "name": t.get("name", ""),
                "duration_ms": t.get("duration_ms", 0),
                "track_number": t.get("track_number"),
            }
            for t in a.get("tracks", [])
        ],
    }
