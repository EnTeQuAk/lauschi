from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from lauschi_catalog.eval.run import load_verdicts, score_root

VERDICT = {
    "id": "kira_kolumna",
    "health": "yellow",
    "completeness": {
        "canon_estimate": 28,
        "missing_examples": ["Folge 27: Gangsterjagd"],
    },
}


class TestLoadVerdicts:
    def test_reads_the_extracted_map(self, tmp_path: Path) -> None:
        p = tmp_path / "v.json"
        p.write_text(json.dumps({"kira_kolumna": VERDICT}))
        assert load_verdicts(p)["kira_kolumna"]["completeness"]["canon_estimate"] == 28

    def test_reads_the_raw_agent_journal_identically(self, tmp_path: Path) -> None:
        p = tmp_path / "journal.jsonl"
        lines = [
            json.dumps({"type": "agent", "key": "x", "result": VERDICT}),
            json.dumps({"type": "agent", "key": "y", "result": "not a verdict"}),
            "",
        ]
        p.write_text("\n".join(lines))
        assert load_verdicts(p) == {"kira_kolumna": VERDICT}


@dataclass
class _Album:
    id: str


class _Provider:
    def __init__(self, name: str, albums: list[str]) -> None:
        self.name = name
        self._albums = albums

    def artist_albums(self, artist_id: str) -> list[_Album]:
        return [_Album(i) for i in self._albums]


def _write(path: Path, curation: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(curation))


def _curation(albums: list[tuple[str, bool, int | None]]) -> dict:
    return {
        "id": "kira_kolumna",
        "provider_artist_ids": {"spotify": ["art"]},
        "albums": [
            {
                "provider": "spotify",
                "album_id": aid,
                "include": inc,
                "episode_num": ep,
                "title": aid,
            }
            for aid, inc, ep in albums
        ],
    }


class TestSplitSeriesTruth:
    def test_parent_albums_count_as_wrong_inclusions_for_the_split_off(
        self, tmp_path: Path
    ) -> None:
        truth_dir = tmp_path / "truth"
        parent = _curation([("p1", True, 1), ("p2", True, 2), ("k1", True, None)])
        parent["id"] = "hanni_und_nanni"
        _write(truth_dir / "hanni_und_nanni.json", parent)
        child = _curation([("k1", True, 1)])
        child["id"] = "kira_kolumna"
        child["split_from"] = "hanni_und_nanni"
        _write(truth_dir / "kira_kolumna.json", child)

        # the curator saw the shared artist page and kept everything
        scratch = tmp_path / "scratch"
        _write(
            scratch / "assets/catalog/curation/kira_kolumna.json",
            _curation([("k1", True, 1), ("p1", True, 1), ("p2", True, 2)]),
        )
        scores, _ = score_root(
            scratch,
            model="m",
            truth_curation_dir=truth_dir,
            providers=[_Provider("spotify", ["k1", "p1", "p2"])],
            verdicts={},
            series_ids=("kira_kolumna",),
        )
        (s,) = scores
        assert s.include_precision == 1 / 3
        assert s.include_recall == 1.0
        assert s.n_outside_truth == 0

    def test_child_albums_count_as_wrong_inclusions_for_the_parent(
        self, tmp_path: Path
    ) -> None:
        truth_dir = tmp_path / "truth"
        parent = _curation([("p1", True, 1), ("p2", True, 2)])
        parent["id"] = "benjamin_bluemchen"
        _write(truth_dir / "benjamin_bluemchen.json", parent)
        child = _curation([("mini1", True, 1), ("mini2", True, 2)])
        child["id"] = "benjamin_minis"
        child["split_from"] = "benjamin_bluemchen"
        _write(truth_dir / "benjamin_minis.json", child)

        # a fresh curation of the parent sees the minis on the shared
        # artist page and keeps one of them
        scratch = tmp_path / "scratch"
        c = _curation(
            [("p1", True, 1), ("p2", True, 2), ("mini1", True, 1), ("mini2", False, 2)]
        )
        c["id"] = "benjamin_bluemchen"
        _write(scratch / "assets/catalog/curation/benjamin_bluemchen.json", c)
        scores, _ = score_root(
            scratch,
            model="m",
            truth_curation_dir=truth_dir,
            providers=[_Provider("spotify", ["p1", "p2", "mini1", "mini2"])],
            verdicts={},
            series_ids=("benjamin_bluemchen",),
        )
        (s,) = scores
        assert s.include_precision == 2 / 3
        assert s.n_outside_truth == 0

    def test_a_series_without_a_parent_is_unaffected(self, tmp_path: Path) -> None:
        truth_dir = tmp_path / "truth"
        _write(truth_dir / "kira_kolumna.json", _curation([("a", True, 1)]))
        scratch = tmp_path / "scratch"
        _write(
            scratch / "assets/catalog/curation/kira_kolumna.json",
            _curation([("a", True, 1), ("b", True, 2)]),
        )
        scores, _ = score_root(
            scratch,
            model="m",
            truth_curation_dir=truth_dir,
            providers=[_Provider("spotify", ["a", "b"])],
            verdicts={},
            series_ids=("kira_kolumna",),
        )
        assert scores[0].include_precision == 1.0
        assert scores[0].n_outside_truth == 1


class TestScoreCriticRoot:
    def test_compares_the_audited_copy_with_the_curator_output(
        self, tmp_path: Path
    ) -> None:
        from lauschi_catalog.eval.run import score_critic_root

        truth_dir = tmp_path / "truth"
        _write(
            truth_dir / "kira_kolumna.json",
            _curation([("a", True, 1), ("box", False, None)]),
        )
        curator = tmp_path / "curator"
        _write(
            curator / "assets/catalog/curation/kira_kolumna.json",
            _curation([("a", True, 1), ("box", True, None)]),
        )
        audited = tmp_path / "audited"
        fixed = _curation([("a", True, 1), ("box", False, None)])
        fixed["review"] = {"status": "approved", "overrides": [{"album_id": "box"}]}
        _write(audited / "assets/catalog/curation/kira_kolumna.json", fixed)

        scores, missing = score_critic_root(
            curator,
            audited,
            critic="c",
            truth_curation_dir=truth_dir,
            providers=[_Provider("spotify", ["a", "box"])],
            verdicts={},
            series_ids=("kira_kolumna", "paw_patrol"),
        )
        assert missing == ["paw_patrol"]
        (s,) = scores
        assert (s.n_mistakes, s.n_fixed, s.n_broken, s.approved) == (1, 1, 0, True)


class TestScoreRoot:
    def test_scores_present_series_and_names_the_unfinished_ones(
        self, tmp_path: Path
    ) -> None:
        truth_dir = tmp_path / "truth"
        _write(
            truth_dir / "kira_kolumna.json",
            _curation([("a", True, 1), ("b", True, 2), ("box", False, None)]),
        )
        scratch = tmp_path / "scratch"
        _write(
            scratch / "assets/catalog/curation/kira_kolumna.json",
            # includes the box set, includes a new album the truth never
            # saw, and recovers the canon gap (episode 27)
            _curation(
                [("a", True, 1), ("b", True, 2), ("box", True, None), ("new", True, 27)]
            ),
        )
        providers = [_Provider("spotify", ["a", "b", "box", "new"])]

        scores, missing = score_root(
            scratch,
            model="m",
            truth_curation_dir=truth_dir,
            providers=providers,
            verdicts={"kira_kolumna": VERDICT},
            series_ids=("kira_kolumna", "paw_patrol"),
        )

        assert missing == ["paw_patrol"]
        (s,) = scores
        assert s.include_precision == 2 / 3
        assert s.include_recall == 1.0
        assert s.hallucinated == frozenset()
        assert s.gap_recovery == 1.0

    def test_an_album_the_providers_never_offered_is_hallucinated(
        self, tmp_path: Path
    ) -> None:
        truth_dir = tmp_path / "truth"
        _write(truth_dir / "kira_kolumna.json", _curation([("a", True, 1)]))
        scratch = tmp_path / "scratch"
        _write(
            scratch / "assets/catalog/curation/kira_kolumna.json",
            _curation([("a", True, 1), ("ghost", True, 2)]),
        )

        scores, _ = score_root(
            scratch,
            model="m",
            truth_curation_dir=truth_dir,
            providers=[_Provider("spotify", ["a"])],
            verdicts={},
            series_ids=("kira_kolumna",),
        )
        assert {f"{k.provider}:{k.album_id}" for k in scores[0].hallucinated} == {
            "spotify:ghost"
        }
