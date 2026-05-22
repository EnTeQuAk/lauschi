"""Shared agent runner with streaming reasoning output."""

from __future__ import annotations

from collections.abc import Callable

from pydantic_ai import CallToolsNode
from pydantic_ai.messages import ThinkingPart
from pydantic_ai.usage import UsageLimits

Progress = Callable[[str], None]
_noop: Progress = lambda _msg: None


async def run_agent_streaming(
    agent,
    prompt,
    deps,
    *,
    request_limit: int = 200,
    response_tokens_limit: int | None = 32_000,
    on_progress: Progress = _noop,
):
    """Run a pydantic-ai agent, streaming thinking parts via callback.

    Returns the agent's structured output. Thinking fragments longer
    than 80 chars are forwarded to ``on_progress``; shorter ones are
    skipped to keep the output readable.
    """
    async with agent.iter(
        prompt, deps=deps,
        usage_limits=UsageLimits(
            request_limit=request_limit,
            response_tokens_limit=response_tokens_limit,
        ),
    ) as run:
        async for node in run:
            if not isinstance(node, CallToolsNode):
                continue
            for part in node.model_response.parts:
                if not isinstance(part, ThinkingPart):
                    continue
                if len(part.content.strip()) <= 80:
                    continue
                snippet = part.content.strip()[:500]
                on_progress(f"  [reasoning] {snippet}")
        return run.result.output
