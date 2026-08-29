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
