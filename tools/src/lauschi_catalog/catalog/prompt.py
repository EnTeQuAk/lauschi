"""Shared prompt-formatting utilities for catalog agents.

Every pipeline phase (curate, audit, finalize) feeds album
metadata to an LLM through prompts. This module provides ONE canonical
formatter so the representation is unified across all phases.
"""

from lauschi_catalog.providers import Album
from lauschi_catalog.reference import ReferenceProduct, ReferenceSeries


def format_album_xml(album: dict, *, include_tracks: bool = True) -> str:
    """Format a single album as XML-tagged metadata.

    The XML structure is designed to be unambiguous for LLM parsing:
    every field is explicitly tagged, and the hierarchy makes the
    relationship between album and tracks clear.

    Args:
        album: dict with keys matching the unified schema:
            provider, id, title, episode_num, release_date,
            album_type, total_tracks, duration_min, label, artist,
            tracks (list of {name, duration_ms, track_number}), and
            optionally episode_range (a RangeFact for a run of episodes).
        include_tracks: whether to inline the track listing.

    Returns:
        XML string (no outer wrapping element).
    """
    lines: list[str] = []
    lines.append(
        f'<album provider="{album.get("provider", "?")}" id="{album.get("id", "?")}">'
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
    run = album.get("episode_range")
    if run is not None:
        alone = ", ".join(str(n) for n in run.released_alone) or "none"
        lines.append(
            f'  <episode_range first="{run.first}" last="{run.last}" '
            f'also_released_alone="{alone}"/>'
        )

    tracks = album.get("tracks", [])
    if include_tracks and tracks:
        lines.append("  <tracks>")
        for t in tracks:
            dur_ms = t.get("duration_ms", 0)
            dur_s = f' duration_ms="{dur_ms}"' if dur_ms else ""
            num = t.get("track_number")
            num_attr = f' num="{num}"' if num else ""
            lines.append(f"    <track{num_attr}{dur_s}>{t.get('name', '')}</track>")
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
            "image_url": d.get("image_url", ""),
            "tracks": [
                {
                    "name": t.get("name", ""),
                    "duration_ms": t.get("duration_ms", 0),
                    "track_number": t.get("track_number"),
                }
                for t in d.get("tracks", [])
            ],
        }

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
            "image_url": album_detail.image_url,
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


def format_reference_lines(
    series: ReferenceSeries, unfiled: list[ReferenceProduct]
) -> str:
    """What the public line index holds for a brand, as a block for the
    instructions of a run on a shared artist page.

    Titles per line with their running time, and the brand's products
    the index files under no line. No episode numbers: they come from the
    provider metadata.
    """
    parts = [
        "## The brand's lines in the public line index",
        "",
        "Several catalog entries share this artist page. The index files the "
        f"releases of {series.name!r} as listed below. A title in a line belongs "
        "to that line. A release under `no_line` is the brand's, and the index "
        "does not say which line: place it by its label, its running time and "
        "the form of its title, next to the titles that are in a line. "
        "The index lags behind new releases and lists only licensed titles, so a "
        "title missing here proves nothing. It gives no episode numbers.",
        "",
    ]
    for line in series.lines:
        titles = [
            f"{episode.title} ({episode.seconds // 60} min)"
            if episode.seconds
            else episode.title
            for episode in line.episodes
            if episode.title
        ]
        if titles:
            parts += [f'<line name="{line.name}">', *titles, "</line>"]
    if unfiled:
        parts.append("<no_line>")
        parts += [
            f"{p.title} ({p.label}, {p.kind}, {(p.seconds or 0) // 60} min)"
            for p in unfiled
        ]
        parts.append("</no_line>")
    return "\n".join(parts)
