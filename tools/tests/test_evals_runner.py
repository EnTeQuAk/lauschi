"""The eval runner: a saved report to compare the next run against.

A change to a prompt or a model is judged by what it does to the cases,
so a run has to be kept and put next to a later one. The saved report
holds the scores, the reasons and what the model answered per album,
not the albums themselves, which the case files hold already.
"""

import io
from pathlib import Path

from pydantic_evals import Case, Dataset
from pydantic_evals.reporting import EvaluationReport
from rich.console import Console

from tests.evals.case_files import load_cases
from tests.evals.evaluators import CatalogOutcome, DecisionsCorrect
from tests.evals.run_evals import (
    BASELINE,
    SMOKE_CASES,
    CaseSummary,
    comparison_table,
    load_report,
    model_requests,
    parse_arguments,
    results_path,
    save_report,
    summarize,
)
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
    assert case.inputs is None and case.metadata is None
    assert "a big batch of albums" not in path.read_text()


def test_a_saved_report_keeps_what_the_model_answered_per_album(
    tmp_path: Path,
) -> None:
    """A score says an album went wrong. The decision with its reason,
    confidence and note says how the model read it, which is what a
    prompt change starts from, and the trace that also holds it expires."""
    path = tmp_path / "baseline.json"

    save_report(_run(ost_included=False), path)
    (case,) = load_report(path).cases

    answers = {album["album_id"]: album for album in case.output["albums"]}
    assert answers["ep1"]["include"] is True
    assert answers["ost"]["include"] is False
    assert answers["ost"]["exclude_reason"] == "wrong_content_type"
    assert {"confidence", "notes"} <= answers["ost"].keys()


def test_a_saved_report_says_which_model_it_came_from(tmp_path: Path) -> None:
    path = tmp_path / "gemma4-31b.json"
    report = _run(ost_included=True)
    report.experiment_metadata = {"model": "gemma4:31b"}

    save_report(report, path)

    assert load_report(path).experiment_metadata == {"model": "gemma4:31b"}


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


def test_the_curator_models_run_is_the_baseline() -> None:
    assert results_path("kimi-k2.6") == BASELINE


def test_another_models_run_never_goes_over_the_baseline() -> None:
    """Every later run is printed against the baseline. A benchmark run
    saved over it would become the yardstick for the next prompt change."""
    assert results_path("gemma4:31b") == BASELINE.parent / "results" / "gemma4-31b.json"
    assert results_path("mistral-large-4").parent == BASELINE.parent / "results"


def test_a_named_run_is_kept_under_its_name_whatever_the_model() -> None:
    """A second round of the curator model, or one setting of another."""
    assert (
        results_path("kimi-k2.6", "kimi-k2.6 round 2")
        == BASELINE.parent / "results" / "kimi-k2.6-round-2.json"
    )


def test_a_report_is_summed_up_per_case_with_every_run() -> None:
    report = _run(ost_included=True, names=("rolf", "sam"))
    report.cases[0].metrics["requests"] = 2

    summary = summarize(report)

    assert summary["rolf"] == CaseSummary(
        right=(0.5,),
        wrong_content=1,
        missing_content=0,
        requests=2,
        seconds=summary["rolf"].seconds,
        failed=0,
    )
    assert set(summary) == {"rolf", "sam"}


def test_saved_runs_are_put_side_by_side_per_case() -> None:
    out = Console(file=io.StringIO(), width=200)

    out.print(
        comparison_table(
            {
                "kimi-k2.6": _run(ost_included=False, names=("rolf", "sam")),
                "gemma4-31b": _run(ost_included=True, names=("rolf",)),
            }
        )
    )

    text = out.file.getvalue()
    rolf = next(line for line in text.splitlines() if "rolf" in line)
    sam = next(line for line in text.splitlines() if "sam" in line)
    assert "kimi-k2.6" in text and "gemma4-31b" in text
    assert "1.00" in rolf and "0.50" in rolf
    assert "1.00" in sam and "not run" in sam


def test_the_smoke_cases_exist() -> None:
    assert set(SMOKE_CASES) <= {case.name for case in load_cases()}


def test_a_run_sends_no_more_cases_at_once_than_the_host_serves() -> None:
    """The host's plan serves three requests at a time and queues the
    rest. A fourth case waited 20 minutes for a slot and was refused."""
    assert parse_arguments([]).max_concurrency == 3
