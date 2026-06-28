"""Task function for curation evals.

Builds a batch curation agent with the real prompts and runs it
against a small batch of albums. Uses the same prompt composition
and model settings as production.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from pydantic_ai import Agent
from pydantic_ai.settings import ModelSettings

from lauschi_catalog._opencode import OPENCODE_BASE_URL, build_model, get_model_settings
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.catalog.curate_ops import BatchResult, CurateDeps
from lauschi_catalog.catalog.prompt import format_albums_xml
from lauschi_catalog.prompts import load_curate_skill

MODEL_NAME = os.environ.get("EVAL_MODEL", "kimi-k2.6")


@dataclass
class BatchInput:
    """Input for a single eval case: series context + albums to classify."""

    series_title: str
    content_type: str
    episode_pattern: str | list[str] | None
    albums: list[dict]
    prior_summary: str = ""
    discography_span_years: int | None = None


def _build_eval_agent(
    inp: BatchInput,
) -> Agent[CurateDeps, BatchResult]:
    """Build a batch agent with real prompts, pointed at the eval model."""
    api_key = os.environ.get("OPENCODE_API_KEY") or os.environ.get("OPENAI_API_KEY", "")
    model = build_model(MODEL_NAME, api_key)

    skill_instructions = load_curate_skill(
        phase="batch",
        content_type=inp.content_type,
        discography_span_years=inp.discography_span_years,
    )
    agent: Agent[CurateDeps, BatchResult] = Agent(
        model,
        output_type=BatchResult,
        instructions=skill_instructions,
        model_settings=get_model_settings("curate", MODEL_NAME),
        retries={"tools": 1, "output": 2},
        toolsets=[build_agent_tools()],
    )
    return agent


def _build_prompt(inp: BatchInput) -> str:
    """Build the user message the batch agent sees."""
    album_xml = format_albums_xml(inp.albums, include_tracks=True)

    parts = [
        f"Series: {inp.series_title!r}",
        f"Episode pattern: {inp.episode_pattern}",
        f"Batch 1 of 1 ({len(inp.albums)} albums)",
    ]
    if inp.prior_summary:
        parts.append(inp.prior_summary)
    parts.append("")
    parts.append(album_xml)

    return "\n".join(parts)


async def run_batch_curation(inp: BatchInput) -> BatchResult:
    """Run the batch curation agent on a small set of albums.

    This is the task function that pydantic_evals calls per case.
    """
    agent = _build_eval_agent(inp)

    deps = CurateDeps(
        pattern=inp.episode_pattern,
    )
    deps.current_batch_ids = {(a["provider"], a["id"]) for a in inp.albums}

    prompt = _build_prompt(inp)
    result = await agent.run(prompt, deps=deps)
    return result.output
