"""A curate run can be read back afterwards, loop or no loop.

Die Schule der magischen Tiere took 107 requests and Unser Sandmännchen
37 at 64K tokens each (2026-09-30), while Stephen Janetzko needed 6 for
687 albums. Only totals were recorded and a successful run left no
trace, so nobody could say which phase spent them or on what. Now every
tool call shows up in the progress lines, the lines are also written to
a per-series transcript, and usage is recorded per phase.
"""

from pathlib import Path

import pytest

from lauschi_catalog import agent_hooks
from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.run import usage_delta


def test_every_tool_call_reports_its_arguments_and_result_size() -> None:
    line = agent_hooks._format_tool_progress(
        "search_excluded_albums", {"query": "Kinofilm", "limit": 20}, [{}, {}, {}]
    )
    assert line == "  search_excluded_albums(query='Kinofilm', limit=20) -> 3 results"
    text = agent_hooks._format_tool_progress("propose_pattern_update", {}, "ok")
    assert text == "  propose_pattern_update() -> 2 chars"


def test_long_tool_arguments_are_shortened() -> None:
    line = agent_hooks._format_tool_progress("lookup", {"q": "x" * 500}, None)
    assert line is not None and len(line) < 200 and line.endswith("-> None")


def test_usage_delta_is_what_one_phase_spent() -> None:
    before = {"requests": 3, "input_tokens": 1000, "output_tokens": 50}
    after = {"requests": 10, "input_tokens": 9000, "output_tokens": 350}
    assert usage_delta(before, after) == {
        "requests": 7,
        "input_tokens": 8000,
        "output_tokens": 300,
    }


def test_the_transcript_keeps_every_progress_line(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(curate_ops, "log_dir", lambda: tmp_path)
    shown: list[str] = []
    with curate_ops.curate_transcript("die_schule", shown.append) as (path, tee):
        tee("== Discovery ==\n")
        tee("  web_search('x') -> 5 results")
    assert shown == ["== Discovery ==\n", "  web_search('x') -> 5 results"]
    assert path.parent == tmp_path / "curate"
    assert path.name.startswith("die_schule-")
    assert path.read_text(encoding="utf-8").splitlines() == [
        "== Discovery ==",
        "  web_search('x') -> 5 results",
    ]


@pytest.mark.anyio
async def test_a_run_reports_what_each_phase_spent(monkeypatch: pytest.MonkeyPatch):
    from pydantic_ai import Agent
    from pydantic_ai.models.test import TestModel

    from lauschi_catalog.catalog.curate_ops import (
        CurateDeps,
        DiscoveryResult,
        SeriesFacts,
        SeriesMetadata,
    )

    monkeypatch.setattr(
        curate_ops, "build_model", lambda _name, _key: TestModel(call_tools=[])
    )

    async def no_albums(*_a, **_k) -> DiscoveryResult:
        return DiscoveryResult(
            all_albums=[], artist_ids={}, provider_errors=[], incomplete=False
        )

    monkeypatch.setattr(curate_ops, "_run_discovery", no_albums)
    monkeypatch.setattr(
        curate_ops,
        "_build_metadata_agent",
        lambda model, **_k: Agent[CurateDeps, SeriesMetadata](
            model, output_type=SeriesMetadata, instructions=""
        ),
    )
    result = await curate_ops._run_large(
        "Kira",
        [],
        model_name="test",
        api_key="test",
        timeout=60,
        existing_facts=SeriesFacts(),
    )
    assert set(result.usage_by_phase) == {"metadata", "batches", "finalize"}
    assert result.usage_by_phase["metadata"]["requests"] >= 1
    assert result.usage_by_phase["batches"]["requests"] == 0
    total = sum(u["requests"] for u in result.usage_by_phase.values())
    assert total == result.usage["requests"]
