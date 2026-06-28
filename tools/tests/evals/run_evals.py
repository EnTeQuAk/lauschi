"""Run curation evals against the real model.

Usage:
    cd tools/
    python -m tests.evals.run_evals
    python -m tests.evals.run_evals --cases benjamin_sub_series,pumuckl_mixed_content
    python -m tests.evals.run_evals --verbose

Requires OPENCODE_API_KEY (or OPENAI_API_KEY) in env.
Set EVAL_MODEL to override the default model (kimi-k2.6).
Set EVAL_JUDGE_MODEL to override the LLM judge model (minimax-m2.7).
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_evals.evaluators import LLMJudge

from .cases import build_dataset
from .task import run_batch_curation

OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"


def _build_judge_model() -> OpenAIChatModel:
    """Build the model used for LLMJudge evaluations."""
    model_name = os.environ.get("EVAL_JUDGE_MODEL", "minimax-m2.7")
    api_key = os.environ.get("OPENCODE_API_KEY") or os.environ.get("OPENAI_API_KEY", "")
    provider = OpenAIProvider(base_url=OPENCODE_BASE_URL, api_key=api_key)
    return OpenAIChatModel(model_name, provider=provider)


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
        "-v", "--verbose",
        action="store_true",
        help="Show detailed output per case",
    )
    args = parser.parse_args()

    names = args.cases.split(",") if args.cases else None
    dataset = build_dataset(names)

    if not dataset.cases:
        print("No cases matched. Available:", ", ".join(c.name for c in build_dataset().cases))
        sys.exit(1)

    judge_model = _build_judge_model()
    for case in dataset.cases:
        for ev in case.evaluators:
            if isinstance(ev, LLMJudge) and ev.model is None:
                ev.model = judge_model

    print(f"Running {len(dataset.cases)} eval case(s)...")
    print(f"  Model: {os.environ.get('EVAL_MODEL', 'kimi-k2.6')}")
    print(f"  Judge: {os.environ.get('EVAL_JUDGE_MODEL', 'minimax-m2.7')}")
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
