"""Ground truth for one series, assembled from sources the repo owns."""

import json
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class AlbumKey:
    provider: str
    album_id: str


@dataclass
class SeriesTruth:
    series_id: str
    #: albums the committed (human-reviewed) curation includes
    included: frozenset[AlbumKey]
    #: albums the committed curation excludes
    excluded: frozenset[AlbumKey]
    #: every album the providers offer for this series (the universe an
    #: honest curation can draw from; anything outside it is invented)
    discography: frozenset[AlbumKey]
    #: episode numbers the canon audit says exist but the catalog lacked
    canon_missing_episodes: frozenset[int] = field(default_factory=frozenset)
    canon_estimate: int | None = None


def _album_keys(albums: list[dict], *, include: bool | None) -> frozenset[AlbumKey]:
    return frozenset(
        AlbumKey(a.get("provider", "?"), a["album_id"])
        for a in albums
        if include is None or bool(a.get("include")) == include
    )


def truth_from_curation(
    curation: dict,
) -> tuple[frozenset[AlbumKey], frozenset[AlbumKey]]:
    """Include/exclude truth from a committed curation."""
    albums = curation.get("albums", [])
    return _album_keys(albums, include=True), _album_keys(albums, include=False)


def discography_from_curation(curation: dict) -> frozenset[AlbumKey]:
    """Every album a curation lists.

    Not the universe for a hallucination check: the provider catalog
    moves (Kira Kolumna grew from 114 to 118 albums between July and
    August 2026), and a curation can carry ids the model invented. The
    universe is the discography replayed from the provider cache, see
    ``discography.fetch_discography``. This helper exists for synthetic
    truths in tests.
    """
    return _album_keys(curation.get("albums", []), include=None)


def _relative_albums(curation: dict, curation_dir: Path) -> frozenset[AlbumKey]:
    """Albums belonging to family members (parent and/or children).

    A split-off sub-series shares its artist pages with the parent, so
    a fresh curation sees the whole family's discography. Albums from
    relatives that are not in this series' included set are treated as
    wrong inclusions for eval purposes.
    """
    from lauschi_catalog.catalog.partition import family_ids_from_curation_dir

    series_id = curation.get("id")
    if not series_id:
        return frozenset()
    parent_id, child_ids = family_ids_from_curation_dir(series_id, curation_dir)
    relative_ids = []
    if parent_id:
        relative_ids.append(parent_id)
    relative_ids.extend(child_ids)
    if not relative_ids:
        return frozenset()
    keys: set[AlbumKey] = set()
    for rel_id in relative_ids:
        path = curation_dir / f"{rel_id}.json"
        if not path.is_file():
            continue
        rel = json.loads(path.read_text(encoding="utf-8"))
        keys |= _album_keys(rel.get("albums", []), include=None)
    return frozenset(keys)


def canon_missing_from_verdict(verdict: dict) -> frozenset[int]:
    """Episode numbers the canon audit named as missing from the catalog.

    The audit wrote free text ("Folge 165: Die doppelte Klassenfahrt —
    released ..."); the leading 'Folge N' is the machine-readable part.
    """
    import re

    out: set[int] = set()
    for text in (verdict.get("completeness") or {}).get("missing_examples") or []:
        m = re.match(r"\s*(?:Folge|Folgen|Teil|Band)\s+(\d+)", str(text))
        if m:
            out.add(int(m.group(1)))
    return frozenset(out)


def load_truth(
    series_id: str,
    *,
    curation_path: Path,
    discography: frozenset[AlbumKey],
    verdict: dict | None,
) -> SeriesTruth:
    curation = json.loads(curation_path.read_text(encoding="utf-8"))
    included, excluded = truth_from_curation(curation)
    relatives = _relative_albums(curation, curation_path.parent)
    excluded |= relatives - included
    return SeriesTruth(
        series_id=series_id,
        included=included,
        excluded=excluded,
        discography=discography,
        canon_missing_episodes=canon_missing_from_verdict(verdict)
        if verdict
        else frozenset(),
        canon_estimate=((verdict or {}).get("completeness") or {}).get(
            "canon_estimate"
        ),
    )
