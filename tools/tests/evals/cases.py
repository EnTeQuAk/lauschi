"""The eval dataset for batch curation.

The cases are files under ``fixtures/``, one batch of albums each with
the decision every album must come out with (see ``case_files``). The
evaluators apply to every case.

Run:
    uv run python -m tests.evals.run_evals
    uv run python -m tests.evals.run_evals --cases benjamin_sub_series
"""

from pydantic_evals import Dataset

from .case_files import load_cases
from .evaluators import (
    CatalogOutcome,
    CatalogTotals,
    ConfidenceMinimum,
    DecisionsCorrect,
    EpisodeNumbersCorrect,
    ExcludeReasonsCorrect,
    NotesPresent,
)
from .task import BatchInput, BatchResult


def build_dataset(names: list[str] | None = None) -> Dataset[BatchInput, BatchResult]:
    """Build the eval dataset, optionally filtering by case name."""
    cases = load_cases()
    if names:
        cases = [c for c in cases if c.name in names]
    return Dataset[BatchInput, BatchResult](
        name="catalog_curation_batch",
        cases=cases,
        evaluators=(
            DecisionsCorrect(),
            ExcludeReasonsCorrect(),
            ConfidenceMinimum(),
            NotesPresent(),
            CatalogOutcome(),
            EpisodeNumbersCorrect(),
        ),
        report_evaluators=(CatalogTotals(),),
    )
