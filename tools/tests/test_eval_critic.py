from __future__ import annotations

from lauschi_catalog.eval.critic import critic_score
from lauschi_catalog.eval.truth import AlbumKey, SeriesTruth


def _album(album_id: str, include: bool) -> dict:
    return {
        "album_id": album_id,
        "provider": "spotify",
        "include": include,
        "title": album_id,
    }


def _key(album_id: str) -> AlbumKey:
    return AlbumKey("spotify", album_id)


TRUTH = SeriesTruth(
    series_id="s",
    included=frozenset({_key("ep1"), _key("ep2"), _key("ep3")}),
    excluded=frozenset({_key("box")}),
    discography=frozenset(
        {_key("ep1"), _key("ep2"), _key("ep3"), _key("box"), _key("new")}
    ),
)

# the curator dropped ep2 and kept the box set: two mistakes
BEFORE = {
    "albums": [
        _album("ep1", True),
        _album("ep2", False),
        _album("ep3", True),
        _album("box", True),
        _album("new", True),
    ]
}


def _after(**flips: bool) -> dict:
    albums = [
        dict(a, include=flips.get(a["album_id"], a["include"]))
        for a in BEFORE["albums"]
    ]
    return {
        "albums": albums,
        "review": {"status": "approved", "overrides": [{"album_id": k} for k in flips]},
    }


def test_a_critic_that_fixes_one_of_two_mistakes_scores_half() -> None:
    s = critic_score(BEFORE, _after(ep2=True), TRUTH, critic="c")
    assert (s.n_mistakes, s.n_fixed, s.n_broken) == (2, 1, 0)
    assert s.fix_rate == 0.5
    assert s.approved is True
    assert s.n_overrides == 1


def test_flipping_a_correct_decision_counts_as_broken() -> None:
    s = critic_score(BEFORE, _after(ep1=False), TRUTH, critic="c")
    assert (s.n_fixed, s.n_broken) == (0, 1)


def test_albums_the_truth_does_not_know_are_ignored_either_way() -> None:
    s = critic_score(BEFORE, _after(new=False), TRUTH, critic="c")
    assert (s.n_mistakes, s.n_fixed, s.n_broken) == (2, 0, 0)


def test_a_curation_without_mistakes_has_no_fix_rate() -> None:
    perfect = {
        "albums": [
            _album("ep1", True),
            _album("ep2", True),
            _album("ep3", True),
            _album("box", False),
        ]
    }
    s = critic_score(perfect, perfect, TRUTH, critic="c")
    assert s.n_mistakes == 0
    assert s.fix_rate is None
    assert s.approved is None
    assert s.n_overrides == 0


def test_an_audit_that_escalated_is_reported_as_not_approved() -> None:
    after = {**_after(), "review": {"status": "escalated", "overrides": []}}
    assert critic_score(BEFORE, after, TRUTH, critic="c").approved is False


def test_the_older_audited_status_counts_as_approved() -> None:
    after = {**_after(), "review": {"status": "audited", "overrides": []}}
    assert critic_score(BEFORE, after, TRUTH, critic="c").approved is True
