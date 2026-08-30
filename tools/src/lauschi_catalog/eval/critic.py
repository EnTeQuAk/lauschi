"""Score a critic (audit model) by what it proposed for a curation.

The critic's judgment is its overrides: ``action: include|exclude``
per album in ``review.overrides``. The pipeline materializes them into
the album flags only when the audit approves, so an escalating critic
leaves the flags alone and the proposals are the only trace of what
it saw. Both are judged the same way, against the truth:

- a *mistake* is an album where the curator disagreed with the truth;
- *fixed* mistakes are the ones the critic proposed to flip to the truth;
- *broken* albums were right and the critic proposed to flip them wrong.

A critic that fixes nothing and breaks nothing is harmless. One that
breaks more than it fixes is worse than no audit at all.
"""

from dataclasses import dataclass

from lauschi_catalog.eval.truth import AlbumKey, SeriesTruth


@dataclass(frozen=True)
class CriticScore:
    series_id: str
    critic: str
    n_mistakes: int
    n_fixed: int
    n_broken: int
    #: what the audit decided, None when the audit left no verdict
    approved: bool | None
    n_overrides: int

    @property
    def fix_rate(self) -> float | None:
        return self.n_fixed / self.n_mistakes if self.n_mistakes else None


def _decisions(curation: dict) -> dict[AlbumKey, bool]:
    return {
        AlbumKey(a.get("provider", "?"), a["album_id"]): bool(a.get("include"))
        for a in curation.get("albums", [])
    }


def _proposals(review: dict) -> dict[AlbumKey, bool]:
    """What the critic wanted each album to be; the last word wins when
    the trail names an album twice."""
    out: dict[AlbumKey, bool] = {}
    for o in review.get("overrides") or []:
        if o.get("action") in ("include", "exclude"):
            out[AlbumKey(o.get("provider", "?"), o["album_id"])] = (
                o["action"] == "include"
            )
    return out


def _truth_decisions(truth: SeriesTruth) -> dict[AlbumKey, bool]:
    return {**{k: False for k in truth.excluded}, **{k: True for k in truth.included}}


def critic_score(
    before: dict, after: dict, truth: SeriesTruth, *, critic: str
) -> CriticScore:
    known = _truth_decisions(truth)
    was = _decisions(before)
    review = after.get("review") or {}
    proposed = _proposals(review)

    mistakes = {k for k, inc in was.items() if k in known and inc != known[k]}
    fixed = {k for k in mistakes if proposed.get(k) == known[k]}
    broken = {
        k
        for k, inc in was.items()
        if k in known and inc == known[k] and k in proposed and proposed[k] != known[k]
    }

    return CriticScore(
        series_id=truth.series_id,
        critic=critic,
        n_mistakes=len(mistakes),
        n_fixed=len(fixed),
        n_broken=len(broken),
        approved=_approved(review.get("status")),
        n_overrides=len(review.get("overrides") or []),
    )


def _approved(status: object) -> bool | None:
    """The audit's verdict from ``review.status``; ``audited`` is the
    older spelling of ``approved`` that audit_ops still accepts."""
    if status in ("approved", "audited"):
        return True
    if status == "escalated":
        return False
    return None
