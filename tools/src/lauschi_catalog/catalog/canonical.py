"""Canonical ordering for curation JSON files.

Three commands write curation JSONs (curate, review, verify). Without
canonical ordering, every re-run produces churn on unrelated entries —
Spotify might return albums in a different order, the agent might
emit overrides in a different sequence — making PR review painful.

This module is the single source of truth for "what does a curation
JSON look like on disk?" Pure in-place mutator, no I/O. Each save
site calls ``canonicalize(data)`` right before ``json.dumps``.

Top-level dict keys are intentionally not sorted: insertion order
keeps related fields adjacent (id/title/content_type, then album
data, then the review block). The churn lives in list contents,
which is where this module focuses.
"""

from __future__ import annotations

from typing import Any

# Used as a sort sentinel for albums whose episode_num is unset. Picks
# infinity rather than a large int so comparisons stay correct even if
# someone ever stores absurdly large numbers.
_NO_EPISODE = float("inf")


def _album_key(album: Any) -> tuple:
    """Sort key for an album entry.

    Order: provider, episode_num (None last), title, album_id.
    Non-dict entries get a constant key — they shouldn't exist, but
    guarding here means a corrupt file doesn't crash the writer.
    """
    if not isinstance(album, dict):
        return ("", _NO_EPISODE, "", "")
    ep = album.get("episode_num")
    return (
        album.get("provider") or "",
        ep if isinstance(ep, int) else _NO_EPISODE,
        album.get("title") or "",
        album.get("album_id") or "",
    )


def _override_key(override: Any) -> tuple:
    if not isinstance(override, dict):
        return ("", "")
    return (override.get("provider") or "", override.get("album_id") or "")


def _split_key(split: Any) -> str:
    if not isinstance(split, dict):
        return ""
    return split.get("new_series_id") or ""


def _era_start_year(era: Any) -> int:
    """Extract start year from era_boundary release_date_range for sorting."""
    if not isinstance(era, dict):
        return 0
    rng = era.get("release_date_range") or ""
    if rng and len(rng) >= 4:
        try:
            return int(rng[:4])
        except ValueError:
            pass
    return 0


def _gap_number(gap: Any) -> int:
    """Extract episode number from known_gap for sorting."""
    if not isinstance(gap, dict):
        return 0
    n = gap.get("number")
    return n if isinstance(n, int) else 0


def _sub_series_label(sub: Any) -> str:
    """Extract label from sub_series for sorting."""
    if not isinstance(sub, dict):
        return ""
    return sub.get("label") or ""


def canonicalize(data: dict) -> None:
    """Sort all unordered lists in a curation JSON in place.

    What gets sorted:
    - ``albums``: by (provider, episode_num, title, album_id).
    - ``review.overrides``: by (provider, album_id).
    - ``review.splits``: by new_series_id, with each split's inner
      ``album_ids`` sorted lexicographically.
    - ``review.added_albums``: same key as albums.
    - ``provider_artist_ids``: list values sorted.
    - ``series_facts.era_boundaries``: by start year.
    - ``series_facts.known_gaps``: by episode number.
    - ``series_facts.sub_series``: by label.

    What's intentionally not touched:
    - ``aliases``: human-curated; order can carry intent (primary alias first).
    - Top-level dict key order: insertion order keeps related fields
      adjacent for human readers.
    """
    albums = data.get("albums")
    if isinstance(albums, list):
        data["albums"] = sorted(albums, key=_album_key)

    pids = data.get("provider_artist_ids")
    if isinstance(pids, dict):
        for k, v in list(pids.items()):
            if isinstance(v, list):
                pids[k] = sorted(v)

    review = data.get("review")
    if isinstance(review, dict):
        overrides = review.get("overrides")
        if isinstance(overrides, list):
            review["overrides"] = sorted(overrides, key=_override_key)

        splits = review.get("splits")
        if isinstance(splits, list):
            for s in splits:
                if isinstance(s, dict):
                    aids = s.get("album_ids")
                    if isinstance(aids, list):
                        s["album_ids"] = sorted(aids)
            review["splits"] = sorted(splits, key=_split_key)

        added = review.get("added_albums")
        if isinstance(added, list):
            review["added_albums"] = sorted(added, key=_album_key)

    facts = data.get("series_facts")
    if isinstance(facts, dict):
        boundaries = facts.get("era_boundaries")
        if isinstance(boundaries, list):
            facts["era_boundaries"] = sorted(boundaries, key=_era_start_year)

        gaps = facts.get("known_gaps")
        if isinstance(gaps, list):
            facts["known_gaps"] = sorted(gaps, key=_gap_number)

        subs = facts.get("sub_series")
        if isinstance(subs, list):
            for s in subs:
                if isinstance(s, dict):
                    aids = s.get("album_ids")
                    if isinstance(aids, list):
                        s["album_ids"] = sorted(aids)
            facts["sub_series"] = sorted(subs, key=_sub_series_label)
