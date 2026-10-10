"""Eval cases stored as files under tests/evals/fixtures/.

A case file holds one batch frozen from the provider cache, the series
facts and prior decisions the run would have, and for every album the
expected decision with the source it rests on. The loader checks the
file and keeps the expectations away from the model's input.
"""

import json
from pathlib import Path
from typing import Any

import pytest

from tests.evals.case_files import FIXTURES, load_case, load_cases
from tests.evals.cases import build_dataset

SERIES = {
    "id": "hexe_lilli",
    "title": "Hexe Lilli",
    "episode_pattern": r"^Folge (\d+):",
}


def _album(album_id: str, title: str, expect: dict[str, Any]) -> dict[str, Any]:
    return {
        "provider": "spotify",
        "id": album_id,
        "title": title,
        "release_date": "2015-01-01",
        "tracks": [{"name": f"{title} - Teil 1", "duration_ms": 600000}],
        "expect": expect,
    }


def _write(tmp_path: Path, **overrides: Any) -> Path:
    data: dict[str, Any] = {
        "question": "Does the main series keep its numbered episodes?",
        "series": SERIES,
        "decided": [],
        "albums": [
            _album(
                "ep2",
                "Folge 2: Feiert Geburtstag",
                {
                    "include": True,
                    "episode_num": 2,
                    "source": "line index: Hörspiele 2",
                },
            ),
            _album(
                "ost",
                "Der Soundtrack zum Film",
                {
                    "include": False,
                    "exclude_reason": [
                        "wrong_content_type",
                        "kinderlieder_compilation",
                    ],
                    "source": "by hand: songs, not a story",
                },
            ),
        ],
    }
    data.update(overrides)
    path = tmp_path / "hexe_lilli_main.json"
    path.write_text(json.dumps(data))
    return path


def test_a_case_file_becomes_a_case(tmp_path: Path) -> None:
    case = load_case(_write(tmp_path))

    assert case.name == "hexe_lilli_main"
    assert case.inputs.series.title == "Hexe Lilli"
    assert case.metadata == {
        ("spotify", "ep2"): {
            "include": True,
            "episode_num": 2,
            "source": "line index: Hörspiele 2",
        },
        ("spotify", "ost"): {
            "include": False,
            "exclude_reason": ["wrong_content_type", "kinderlieder_compilation"],
            "source": "by hand: songs, not a story",
        },
    }


def test_the_expectations_stay_out_of_the_models_input(tmp_path: Path) -> None:
    case = load_case(_write(tmp_path))

    assert [a["id"] for a in case.inputs.albums] == ["ep2", "ost"]
    assert all("expect" not in a for a in case.inputs.albums)


def test_prior_decisions_and_shipped_albums_are_read(tmp_path: Path) -> None:
    decided = [
        {
            "album_id": "ep1",
            "provider": "spotify",
            "title": "Folge 1: Zaubert Hausaufgaben",
            "include": True,
            "episode_num": 1,
        }
    ]
    path = _write(
        tmp_path, decided=decided, series={**SERIES, "ships": [["spotify", "ep1"]]}
    )

    case = load_case(path)

    assert case.inputs.decided == decided
    assert case.inputs.series.ships == [("spotify", "ep1")]


@pytest.mark.parametrize(
    ("expect", "problem"),
    [
        ({"include": True}, "source"),
        ({"include": True, "source": ""}, "source"),
        (
            {"include": False, "exclude_reason": "boring", "source": "by hand"},
            "exclude_reason",
        ),
        (
            {"include": True, "exclude_reason": "compilation", "source": "by hand"},
            "included album cannot carry an exclude_reason",
        ),
        (
            {"include": False, "episode_num": 3, "source": "by hand"},
            "excluded album cannot carry an episode_num",
        ),
        ({"include": True, "source": "by hand", "episode": 3}, "episode"),
    ],
)
def test_a_wrong_expectation_is_refused(
    tmp_path: Path, expect: dict[str, Any], problem: str
) -> None:
    path = _write(tmp_path, albums=[_album("ep2", "Folge 2: Geburtstag", expect)])

    with pytest.raises(ValueError, match=problem):
        load_case(path)


def test_an_album_cannot_be_asked_and_already_decided(tmp_path: Path) -> None:
    decided = [
        {
            "album_id": "ep2",
            "provider": "spotify",
            "title": "Folge 2: Feiert Geburtstag",
            "include": True,
            "episode_num": 2,
        }
    ]

    with pytest.raises(ValueError, match="spotify:ep2 is both asked and decided"):
        load_case(_write(tmp_path, decided=decided))


def test_every_committed_case_file_loads() -> None:
    cases = load_cases()

    assert [c.name for c in cases] == sorted(p.stem for p in FIXTURES.glob("*.json"))
    assert cases, "no case files under tests/evals/fixtures"


def test_the_dataset_holds_the_case_files() -> None:
    dataset = build_dataset()

    assert {c.name for c in load_cases()} <= {c.name for c in dataset.cases}
    assert [c.name for c in build_dataset(["hexe_lilli_erstleser_own_line"]).cases] == [
        "hexe_lilli_erstleser_own_line"
    ]
