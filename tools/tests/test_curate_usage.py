import asyncio
import json
from pathlib import Path

import pytest
from pydantic_ai import Agent
from pydantic_ai.models.test import TestModel
from pydantic_ai.usage import RunUsage

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    CuratedSeries,
    save_curation,
    usage_summary,
)
from lauschi_catalog.run import run_agent


def test_run_agent_adds_each_run_to_the_tally() -> None:
    agent = Agent(TestModel(custom_output_text="ok"), output_type=str)
    tally = RunUsage()
    asyncio.run(run_agent(agent, "one", None, tally=tally))
    asyncio.run(run_agent(agent, "two", None, tally=tally))
    assert tally.requests == 2
    assert tally.input_tokens > 0
    assert tally.output_tokens > 0


def test_run_agent_without_a_tally_counts_nothing() -> None:
    agent = Agent(TestModel(custom_output_text="ok"), output_type=str)
    assert asyncio.run(run_agent(agent, "one", None)) == "ok"


def test_usage_summary_is_the_three_numbers_a_cost_needs() -> None:
    u = RunUsage(requests=3, input_tokens=1200, output_tokens=340)
    assert usage_summary(u) == {
        "requests": 3,
        "input_tokens": 1200,
        "output_tokens": 340,
    }


def test_save_curation_persists_who_curated_and_what_it_cost(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(curate_ops, "CURATION_DIR", tmp_path)
    series = CuratedSeries(
        id="kira_kolumna",
        title="Kira Kolumna",
        albums=[],
        curated_by="gpt-5.6-luna",
        usage={"requests": 5, "input_tokens": 40000, "output_tokens": 6000},
    )
    path = save_curation(series)
    data = json.loads(path.read_text())
    assert data["curated_by"] == "gpt-5.6-luna"
    assert data["usage"] == {
        "requests": 5,
        "input_tokens": 40000,
        "output_tokens": 6000,
    }
