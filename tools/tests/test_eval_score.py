"""The eval scorer must be right before it judges a real curation.

Every test builds a tiny synthetic curation and a truth by hand, so the
expected numbers can be checked with a pencil.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.eval.sample import SAMPLE, SAMPLE_IDS
from lauschi_catalog.eval.score import score
from lauschi_catalog.eval.truth import (
    AlbumKey,
    SeriesTruth,
    canon_missing_from_verdict,
    discography_from_curation,
    truth_from_curation,
)


def _album(
    album_id: str,
    *,
    include: bool,
    episode_num: int | None = None,
    provider: str = "spotify",
) -> dict:
    return {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": f"Folge {episode_num}" if episode_num else "Something",
    }


def _key(album_id: str, provider: str = "spotify") -> AlbumKey:
    return AlbumKey(provider, album_id)


COMMITTED = {
    "albums": [
        _album("a1", include=True, episode_num=1),
        _album("a2", include=True, episode_num=2),
        _album("a3", include=True, episode_num=3),
        _album("box", include=False),
        _album("a1", include=True, episode_num=1, provider="apple_music"),
    ]
}


def _truth(**overrides) -> SeriesTruth:
    included, excluded = truth_from_curation(COMMITTED)
    base = dict(
        series_id="synthetic",
        included=included,
        excluded=excluded,
        discography=discography_from_curation(COMMITTED),
    )
    base.update(overrides)
    return SeriesTruth(**base)


class TestTruthFromCommittedCuration:
    def test_splits_include_and_exclude_by_provider_and_id(self) -> None:
        included, excluded = truth_from_curation(COMMITTED)
        assert included == {
            _key("a1"),
            _key("a2"),
            _key("a3"),
            _key("a1", "apple_music"),
        }
        assert excluded == {_key("box")}

    def test_discography_is_every_album_the_curation_saw(self) -> None:
        assert discography_from_curation(COMMITTED) == {
            _key("a1"),
            _key("a2"),
            _key("a3"),
            _key("box"),
            _key("a1", "apple_music"),
        }

    def test_same_id_on_two_providers_is_two_albums(self) -> None:
        # Spotify and Apple ids never collide in practice, but the key
        # must still carry the provider so a cross-provider pair counts
        # twice, the way the pipeline treats it.
        assert _key("a1") != _key("a1", "apple_music")


class TestCanonMissingFromVerdict:
    @pytest.mark.parametrize(
        "examples, expected",
        [
            (["Folge 165: Die doppelte Klassenfahrt (2026)"], {165}),
            (["Folge 27", "Folge 28: Something"], {27, 28}),
            (["  Folge 3 is missing on Spotify"], {3}),
            (["Teil 2", "Band 7"], {2, 7}),
            (["some prose without a number"], set()),
            ([], set()),
        ],
    )
    def test_parses_the_leading_episode_number(
        self, examples: list[str], expected: set[int]
    ) -> None:
        verdict = {"completeness": {"missing_examples": examples}}
        assert canon_missing_from_verdict(verdict) == frozenset(expected)

    def test_tolerates_a_verdict_without_completeness(self) -> None:
        assert canon_missing_from_verdict({}) == frozenset()
        assert canon_missing_from_verdict({"completeness": None}) == frozenset()


class TestScore:
    def test_perfect_reproduction_scores_one_on_both_with_no_hallucination(
        self,
    ) -> None:
        s = score(COMMITTED, _truth(), model="m")
        assert s.include_precision == 1.0
        assert s.include_recall == 1.0
        assert s.hallucinated == frozenset()
        assert s.n_included == 4
        assert s.n_truth_included == 4

    def test_including_the_box_set_costs_precision_not_recall(self) -> None:
        curation = {"albums": [dict(a, include=True) for a in COMMITTED["albums"]]}
        s = score(curation, _truth(), model="m")
        assert s.include_precision == pytest.approx(4 / 5)
        assert s.include_recall == 1.0

    def test_dropping_a_real_episode_costs_recall_not_precision(self) -> None:
        curation = {
            "albums": [
                dict(a, include=False) if a["album_id"] == "a2" else a
                for a in COMMITTED["albums"]
            ]
        }
        s = score(curation, _truth(), model="m")
        assert s.include_precision == 1.0
        assert s.include_recall == pytest.approx(3 / 4)

    def test_an_included_album_outside_the_discography_is_hallucinated(self) -> None:
        curation = {
            "albums": [
                *COMMITTED["albums"],
                _album("invented", include=True, episode_num=99),
            ]
        }
        s = score(curation, _truth(), model="m")
        assert s.hallucinated == {_key("invented")}

    def test_hallucinations_do_not_count_toward_precision(self) -> None:
        # Precision is judged on grounded albums only. A hallucination is
        # reported separately as the disqualifier; it must not also be
        # quietly folded into a ratio where it could be averaged away.
        curation = {
            "albums": [
                *COMMITTED["albums"],
                _album("invented", include=True, episode_num=99),
            ]
        }
        s = score(curation, _truth(), model="m")
        assert s.include_precision == 1.0
        assert s.n_included == 5

    def test_gap_recovery_is_the_share_of_canon_missing_episodes_now_included(
        self,
    ) -> None:
        truth = _truth(canon_missing_episodes=frozenset({2, 40}))
        # episode 2 is included, episode 40 is nowhere
        s = score(COMMITTED, truth, model="m")
        assert s.gap_recovery == pytest.approx(1 / 2)

    def test_gap_recovery_is_none_when_canon_names_no_gaps(self) -> None:
        s = score(COMMITTED, _truth(), model="m")
        assert s.gap_recovery is None

    def test_an_excluded_album_does_not_recover_a_gap(self) -> None:
        truth = _truth(canon_missing_episodes=frozenset({2}))
        curation = {
            "albums": [
                dict(a, include=False) if a["album_id"] == "a2" else a
                for a in COMMITTED["albums"]
            ]
        }
        s = score(curation, truth, model="m")
        assert s.gap_recovery == 0.0

    def test_a_new_album_unknown_to_the_truth_is_neither_right_nor_wrong(
        self,
    ) -> None:
        # Offered by the provider (in the discography) but released after
        # the truth was written: not a hallucination, not a precision hit.
        new = _album("released_later", include=True, episode_num=4)
        truth = _truth(
            discography=discography_from_curation(COMMITTED) | {_key("released_later")}
        )
        s = score({"albums": [*COMMITTED["albums"], new]}, truth, model="m")
        assert s.hallucinated == frozenset()
        assert s.include_precision == 1.0
        assert s.n_outside_truth == 1

    def test_disagreements_name_only_albums_the_truth_knows(self) -> None:
        curation = {
            "albums": [
                # real episode dropped, with a reason
                dict(
                    COMMITTED["albums"][1], include=False, exclude_reason="compilation"
                ),
                COMMITTED["albums"][0],
                COMMITTED["albums"][2],
                # box set kept
                dict(COMMITTED["albums"][3], include=True),
                COMMITTED["albums"][4],
                # unknown to the truth: not a disagreement
                _album("released_later", include=True, episode_num=9),
            ]
        }
        s = score(curation, _truth(), model="m")
        got = {
            (d.album_id, d.truth_include, d.model_include, d.reason)
            for d in s.disagreements
        }
        assert got == {("a2", True, False, "compilation"), ("box", False, True, "")}

    def test_the_incomplete_flag_of_the_run_is_carried(self) -> None:
        assert score({**COMMITTED, "incomplete": True}, _truth(), model="m").incomplete
        assert not score(COMMITTED, _truth(), model="m").incomplete

    def test_albums_the_model_never_decided_are_counted(self) -> None:
        # curate's _restore_dropped_albums marks these with a fixed note
        # prefix; the count is the curator's coverage failure.
        curation = {
            "albums": [
                *COMMITTED["albums"][:3],
                dict(
                    COMMITTED["albums"][3],
                    include=True,
                    notes="auto-included: agent omitted this album from its output",
                ),
                dict(
                    COMMITTED["albums"][4],
                    notes="auto-included: agent omitted this album",
                ),
            ]
        }
        s = score(curation, _truth(), model="m")
        assert s.n_auto_included == 2
        assert score(COMMITTED, _truth(), model="m").n_auto_included == 0

    def test_an_empty_curation_has_zero_recall(self) -> None:
        # Precision is vacuously 1.0 here (nothing wrong was included);
        # the report always shows both numbers so this cannot pass as good.
        s = score({"albums": []}, _truth(), model="m")
        assert s.include_recall == 0.0
        assert s.include_precision == 1.0
        assert s.n_included == 0


class TestSample:
    def test_twelve_distinct_series_across_every_stratum(self) -> None:
        assert len(SAMPLE_IDS) == 12
        assert len(set(SAMPLE_IDS)) == 12
        assert {s.stratum for s in SAMPLE} == {
            "big_numbered",
            "mid_numbered",
            "split_subseries",
            "music",
            "chunked",
        }

    def test_every_sample_series_exists_in_the_catalog(self) -> None:
        from lauschi_catalog.catalog.loader import load_catalog

        ids = {s.id for s in load_catalog()}
        missing = set(SAMPLE_IDS) - ids
        assert not missing, missing
