"""Run curation evals against the real model.

Usage:
    mise run catalog-evals                  # every case three times, four at once
    mise run catalog-evals -- --smoke       # three quick cases once, to check the setup
    mise run catalog-evals -- --cases feuerwehrmann_sam_boxes --repeat 1 -v
    mise run catalog-evals -- --save        # keep the run as the baseline

A case calls the model and its tools for real, so two runs of one case
can differ. Repeats show that as a spread instead of as a result. A run
is printed next to the saved baseline (baseline.json) when there is one.

Requires the model host's API key (OLLAMA_API_KEY by default, see
lauschi_catalog._opencode.model_host).
A run is traced to Logfire like a CLI run, when the checkout holds a
Logfire credential (see "Tracing agent runs" in AGENTS.md).
Set EVAL_MODEL to override the default model (kimi-k2.6).
"""

import argparse
import asyncio
import os
import sys
from dataclasses import replace
from pathlib import Path

from pydantic_evals.reporting import EvaluationReport, EvaluationReportAdapter

from lauschi_catalog.observability import configure_observability

from .cases import build_dataset
from .task import run_batch_curation

BASELINE = Path(__file__).parent / "baseline.json"

#: quick cases that between them touch a sub-series, a box rule and a
#: plain batch, for checking the setup before a full run
SMOKE_CASES = (
    "benjamin_sub_series",
    "feuerwehrmann_sam_boxes",
    "wieso_vorlesegeschichten_takes_nothing",
)


def save_report(report: EvaluationReport, path: Path) -> None:
    """Keep a run to compare later runs against: scores, assertions with
    their reasons, metrics and durations per case. The albums and the
    decisions stay out, the case files hold the albums already."""
    slim = replace(
        report,
        cases=[
            replace(case, inputs=None, metadata=None, output=None)
            for case in report.cases
        ],
    )
    path.write_bytes(EvaluationReportAdapter.dump_json(slim, indent=1) + b"\n")


def load_report(path: Path) -> EvaluationReport:
    return EvaluationReportAdapter.validate_json(path.read_bytes())


def model_requests(report: EvaluationReport) -> int:
    """Model requests of the whole run. The count per case comes from
    the tracing, so it is 0 for a run that was not traced."""
    return int(sum(case.metrics.get("requests", 0) for case in report.cases))


def main() -> None:
    parser = argparse.ArgumentParser(description="Run catalog curation evals")
    parser.add_argument(
        "--cases",
        type=str,
        default=None,
        help="Comma-separated case names to run (default: all)",
    )
    parser.add_argument(
        "--smoke",
        action="store_true",
        help=f"Run only {', '.join(SMOKE_CASES)}",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=3,
        help="Runs per case (default: 3, a smoke run does 1)",
    )
    parser.add_argument(
        "--max-concurrency",
        type=int,
        default=4,
        help="Max concurrent eval cases (default: 4)",
    )
    parser.add_argument(
        "--save",
        action="store_true",
        help=f"Save the run as the baseline ({BASELINE.name})",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show inputs, outputs and reasons per case",
    )
    args = parser.parse_args()
    configure_observability()

    names = list(SMOKE_CASES) if args.smoke else None
    if args.cases:
        names = args.cases.split(",")
    repeat = 1 if args.smoke else args.repeat
    dataset = build_dataset(names)

    if not dataset.cases:
        print(
            "No cases matched. Available:",
            ", ".join(c.name for c in build_dataset().cases),
        )
        sys.exit(1)

    print(f"Running {len(dataset.cases)} eval case(s), {repeat} time(s) each...")
    print(f"  Model: {os.environ.get('EVAL_MODEL', 'kimi-k2.6')}")
    print()

    report = asyncio.run(
        dataset.evaluate(
            run_batch_curation,
            max_concurrency=args.max_concurrency,
            repeat=repeat,
        )
    )

    report.print(
        baseline=load_report(BASELINE) if BASELINE.exists() else None,
        include_input=args.verbose,
        include_output=args.verbose,
        include_reasons=args.verbose,
    )
    print(f"\nModel requests: {model_requests(report)}")
    if args.save:
        save_report(report, BASELINE)
        print(f"Saved as the baseline: {BASELINE}")
    if report.failures:
        print(f"\n{len(report.failures)} case run(s) did not finish.")
        sys.exit(1)


if __name__ == "__main__":
    main()
