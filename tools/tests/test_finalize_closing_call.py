"""The finalize agent closes its phase with a named call.

Facts and pattern changes go through tools, so the result carried nothing,
while the prompt still asked for a `FinalizeResult` with episode_updates
and for notes "in your response". GLM-5.3 closed 31 of 34 finalize runs
with a text summary. The run refuses text, each refusal costs a retry, and
a finalize that runs out of retries marks the whole series incomplete.
"""

import pytest
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import CurateDeps, FinalizeResult
from lauschi_catalog.prompts import load_curate_skill

NOTES = "Batch 3 excluded two Folgen that the other batches included."


@pytest.mark.anyio
async def test_the_prompt_names_the_call_that_closes_the_phase() -> None:
    offered: list[str] = []

    def answer(_messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        offered.append(info.output_tools[0].name)
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"notes": NOTES})]
        )

    agent = curate_ops._build_finalize_agent(FunctionModel(answer))
    result = await agent.run("Finalize the curation", deps=CurateDeps())

    assert offered == ["finish_finalize"]
    assert result.output.notes == NOTES
    assert "call `finish_finalize`" in load_curate_skill(phase="finalize")


def test_the_prompt_asks_for_nothing_the_closing_call_cannot_carry() -> None:
    prompt = load_curate_skill(phase="finalize")

    assert "episode_updates" not in prompt
    assert "your response" not in prompt
    assert "`notes`" in prompt


def test_closing_notes_go_into_the_run_log() -> None:
    line = curate_ops._finalize_notes_line(FinalizeResult(notes=f" {NOTES}\n"))

    assert line == f"  Finalize notes: {NOTES}\n"


def test_a_closing_call_without_notes_logs_nothing() -> None:
    assert curate_ops._finalize_notes_line(FinalizeResult()) == ""
