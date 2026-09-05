"""Decision-by-decision comparison of two curations of one series.

The determinism panel curates a series twice from a clean directory and
compares the results. What a child would notice (an include flag, an
episode number) is kept apart from what only a reviewer reads (the
reason label on an excluded album).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class CurationDiff:
    include_flips: tuple[tuple[str, str, bool, bool], ...]
    episode_diffs: tuple[tuple[str, str, int | None, int | None], ...]
    reason_diffs: tuple[tuple[str, str, str | None, str | None], ...]
    only_a: tuple[tuple[str, str], ...]
    only_b: tuple[tuple[str, str], ...]

    @property
    def identical(self) -> bool:
        return not (
            self.include_flips
            or self.episode_diffs
            or self.reason_diffs
            or self.only_a
            or self.only_b
        )


def _by_key(curation: dict) -> dict[tuple[str, str], dict]:
    return {
        (a.get("provider", ""), a["album_id"]): a for a in curation.get("albums", [])
    }


def diff_curations(a: dict, b: dict) -> CurationDiff:
    """Compare two curation dicts of the same series, keyed by (provider, album_id)."""
    ka, kb = _by_key(a), _by_key(b)
    common = sorted(set(ka) & set(kb))
    flips = []
    episodes = []
    reasons = []
    for key in common:
        x, y = ka[key], kb[key]
        if bool(x.get("include")) != bool(y.get("include")):
            flips.append((*key, bool(x.get("include")), bool(y.get("include"))))
        if x.get("episode_num") != y.get("episode_num"):
            episodes.append((*key, x.get("episode_num"), y.get("episode_num")))
        if x.get("exclude_reason") != y.get("exclude_reason"):
            reasons.append((*key, x.get("exclude_reason"), y.get("exclude_reason")))
    return CurationDiff(
        include_flips=tuple(flips),
        episode_diffs=tuple(episodes),
        reason_diffs=tuple(reasons),
        only_a=tuple(sorted(set(ka) - set(kb))),
        only_b=tuple(sorted(set(kb) - set(ka))),
    )
