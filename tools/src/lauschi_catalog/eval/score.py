"""Score one model's curation of one series against its ground truth.

Every number here is a plain ratio over sets, so two people running it
on the same files get the same result.
"""

from __future__ import annotations

from dataclasses import dataclass

from lauschi_catalog.eval.truth import AlbumKey, SeriesTruth


@dataclass(frozen=True)
class Score:
    series_id: str
    model: str
    #: of albums the model included, the share the truth also includes.
    #: Guards against wrong content reaching a child.
    include_precision: float
    #: of albums the truth includes, the share the model included.
    include_recall: float
    #: albums the model included that are not in the discography at all.
    #: Invented content. Any nonzero value disqualifies a curator.
    hallucinated: frozenset[AlbumKey]
    #: of episodes the canon audit said were missing from the catalog,
    #: the share this curation now includes (found what the old one lacked).
    gap_recovery: float | None
    #: albums the model never decided. Curate includes those by default
    #: (``_restore_dropped_albums``), so a curator that skips albums
    #: ships them to children with low confidence. Coverage failure.
    n_auto_included: int
    #: included albums the providers offer but the truth never saw
    #: (released after it was written). Neither right nor wrong here.
    n_outside_truth: int
    n_included: int
    n_truth_included: int


def _included_keys(curation: dict) -> frozenset[AlbumKey]:
    return frozenset(
        AlbumKey(a.get("provider", "?"), a["album_id"])
        for a in curation.get("albums", [])
        if a.get("include")
    )


def _included_episodes(curation: dict) -> frozenset[int]:
    return frozenset(
        a["episode_num"]
        for a in curation.get("albums", [])
        if a.get("include") and a.get("episode_num") is not None
    )


AUTO_INCLUDED_NOTE = "auto-included:"


def _auto_included(curation: dict) -> int:
    return sum(
        1
        for a in curation.get("albums", [])
        if str(a.get("notes") or "").startswith(AUTO_INCLUDED_NOTE)
    )


def _ratio(num: int, den: int) -> float:
    return num / den if den else 1.0


def score(curation: dict, truth: SeriesTruth, *, model: str) -> Score:
    included = _included_keys(curation)
    hallucinated = included - truth.discography
    grounded = included & truth.discography
    # Precision is judged only on albums the truth has an opinion on.
    # The provider catalog keeps growing after a truth is written, and
    # a real new episode the model included is not a wrong inclusion.
    judged = grounded & (truth.included | truth.excluded)

    precision = _ratio(len(judged & truth.included), len(judged))
    recall = _ratio(len(grounded & truth.included), len(truth.included))

    gap_recovery: float | None = None
    if truth.canon_missing_episodes:
        found = _included_episodes(curation) & truth.canon_missing_episodes
        gap_recovery = _ratio(len(found), len(truth.canon_missing_episodes))

    return Score(
        series_id=truth.series_id,
        model=model,
        include_precision=precision,
        include_recall=recall,
        hallucinated=frozenset(hallucinated),
        gap_recovery=gap_recovery,
        n_auto_included=_auto_included(curation),
        n_outside_truth=len(grounded - judged),
        n_included=len(included),
        n_truth_included=len(truth.included),
    )
