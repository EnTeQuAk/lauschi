"""The eval runner: a saved report to compare the next run against.

A change to a prompt or a model is judged by what it does to the cases,
so a run has to be kept and put next to a later one. The saved report
holds the scores and the reasons, not the albums, which the case files
hold already.
"""

import io
from pathlib import Path

from pydantic_evals import Case, Dataset
from pydantic_evals.reporting import EvaluationReport
from rich.console import Console

from tests.evals.case_files import load_cases
from tests.evals.evaluators import CatalogOutcome, DecisionsCorrect
from tests.evals.run_evals import SMOKE_CASES, load_report, model_requests, save_report
from tests.evals.task import BatchResult
from tests.factories import decision

EXPECTED = {
    ("spotify", "ep1"): {"include": True, "source": "by hand"},
    ("spotify", "ost"): {"include": False, "source": "by hand"},
}


def _run(*, ost_included: bool, names: tuple[str, ...] = ("case",)) -> EvaluationReport:
    answer = BatchResult(
        albums=[
            decision("ep1", episode_num=1),
            decision(
                "ost",
                include=ost_included,
                exclude_reason=None if ost_included else "wrong_content_type",
            ),
        ]
    )
    dataset = Dataset(
        name="runner",
        cases=[
            Case(name=name, inputs="a big batch of albums", metadata=EXPECTED)
            for name in names
        ],
        evaluators=[DecisionsCorrect(), CatalogOutcome()],
    )
    return dataset.evaluate_sync(lambda _: answer, progress=False)


def test_a_saved_report_keeps_scores_and_reasons_but_not_the_albums(
    tmp_path: Path,
) -> None:
    path = tmp_path / "baseline.json"

    save_report(_run(ost_included=True), path)
    (case,) = load_report(path).cases

    assert case.scores["wrong_content"].value == 1
    assert "included, expected exclude" in (
        case.assertions["decisions_correct"].reason or ""
    )
    assert case.inputs is None and case.output is None and case.metadata is None
    assert "a big batch of albums" not in path.read_text()


def test_a_later_run_is_printed_against_the_saved_one(tmp_path: Path) -> None:
    path = tmp_path / "baseline.json"
    save_report(_run(ost_included=True), path)
    out = Console(file=io.StringIO(), width=200)

    _run(ost_included=False).print(baseline=load_report(path), console=out)

    text = out.file.getvalue()
    assert "Evaluation Diff" in text
    assert "0.500 → 1.00" in text


def test_saving_a_run_of_some_cases_keeps_the_others(tmp_path: Path) -> None:
    """One change is measured on the cases it touches. Saving that run
    must not throw the rest of the baseline away."""
    path = tmp_path / "baseline.json"
    save_report(_run(ost_included=True, names=("rolf", "sam")), path)

    save_report(_run(ost_included=False, names=("rolf",)), path, keep={"rolf", "sam"})

    saved = {
        case.name: case.scores["wrong_content"].value
        for case in load_report(path).cases
    }
    assert saved == {"sam": 1, "rolf": 0}


def test_a_case_that_is_gone_leaves_the_baseline(tmp_path: Path) -> None:
    path = tmp_path / "baseline.json"
    save_report(_run(ost_included=True, names=("bibi", "sam")), path)

    save_report(_run(ost_included=False, names=("sam",)), path, keep={"sam"})

    assert [case.name for case in load_report(path).cases] == ["sam"]


def test_model_requests_are_added_up_over_the_cases() -> None:
    report = _run(ost_included=True)
    report.cases[0].metrics["requests"] = 3
    report.cases.append(report.cases[0])

    assert model_requests(report) == 6


def test_the_smoke_cases_exist() -> None:
    assert set(SMOKE_CASES) <= {case.name for case in load_cases()}
