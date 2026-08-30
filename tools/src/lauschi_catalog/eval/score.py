"""Score one model's curation of one series against its ground truth.

Every number here is a plain ratio over sets, so two people running it
on the same files get the same result.
"""

from __future__ import annotations

from dataclasses import dataclass

from lauschi_catalog.eval.truth import AlbumKey, SeriesTruth


@dataclass(frozen=True)
class Disagreement:
    provider: str
    album_id: str
    title: str
    truth_include: bool
    model_include: bool
    #: the model's exclude_reason or notes, whichever it gave
    reason: str


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
    #: included albums the providers offer but the truth never saw
    #: (released after it was written). Neither right nor wrong here.
    n_outside_truth: int
    n_included: int
    n_truth_included: int
    #: albums the model never decided and left absent.
    n_undecided: int
    #: curate gave up part-way (a batch failed) and left remaining
    #: albums undecided; the ratios above describe that artifact, not the model.
    incomplete: bool
    #: every album the truth knows where the model decided differently
    disagreements: tuple[Disagreement, ...]


def _undecided(curation: dict) -> int:
    """Albums present in the source but not in the curation output.

    Undecided albums are left absent from the curation, which marks the
    run incomplete so apply cannot ship them. The current truth object
    does not carry source album ids, so this stays 0 until the truth
    model is extended to include them.
    """
    return 0


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


def disagreements(curation: dict, truth: SeriesTruth) -> tuple[Disagreement, ...]:
    out: list[Disagreement] = []
    for a in curation.get("albums", []):
        key = AlbumKey(a.get("provider", "?"), a["album_id"])
        if key in truth.included:
            truth_include = True
        elif key in truth.excluded:
            truth_include = False
        else:
            continue
        model_include = bool(a.get("include"))
        if model_include == truth_include:
            continue
        out.append(
            Disagreement(
                provider=key.provider,
                album_id=key.album_id,
                title=str(a.get("title") or ""),
                truth_include=truth_include,
                model_include=model_include,
                reason=str(a.get("exclude_reason") or a.get("notes") or ""),
            )
        )
    return tuple(sorted(out, key=lambda d: (d.provider, d.title, d.album_id)))


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
        n_outside_truth=len(grounded - judged),
        n_included=len(included),
        n_truth_included=len(truth.included),
        n_undecided=_undecided(curation),
        incomplete=bool(curation.get("incomplete")),
        disagreements=disagreements(curation, truth),
    )
