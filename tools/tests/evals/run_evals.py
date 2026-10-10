"""Run curation evals against the real model.

Usage:
    cd tools/
    python -m tests.evals.run_evals
    python -m tests.evals.run_evals --cases benjamin_sub_series,pumuckl_mixed_content
    python -m tests.evals.run_evals --verbose

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

from lauschi_catalog.observability import configure_observability

from .cases import build_dataset
from .task import run_batch_curation


def main() -> None:
    parser = argparse.ArgumentParser(description="Run catalog curation evals")
    parser.add_argument(
        "--cases",
        type=str,
        default=None,
        help="Comma-separated case names to run (default: all)",
    )
    parser.add_argument(
        "--max-concurrency",
        type=int,
        default=1,
        help="Max concurrent eval cases (default: 1)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Show detailed output per case",
    )
    args = parser.parse_args()
    configure_observability()

    names = args.cases.split(",") if args.cases else None
    dataset = build_dataset(names)

    if not dataset.cases:
        print(
            "No cases matched. Available:",
            ", ".join(c.name for c in build_dataset().cases),
        )
        sys.exit(1)

    print(f"Running {len(dataset.cases)} eval case(s)...")
    print(f"  Model: {os.environ.get('EVAL_MODEL', 'kimi-k2.6')}")
    print()

    report = asyncio.run(
        dataset.evaluate(
            run_batch_curation,
            max_concurrency=args.max_concurrency,
        )
    )

    report.print(
        include_input=args.verbose,
        include_output=args.verbose,
        include_reasons=args.verbose,
    )

    averages = report.averages()
    if averages is None or averages.assertions is None:
        print("\nNo assertions recorded.")
        sys.exit(1)

    pass_rate = averages.assertions
    print(f"\nOverall pass rate: {pass_rate:.0%}")
    sys.exit(0 if pass_rate == 1.0 else 1)


if __name__ == "__main__":
    main()
