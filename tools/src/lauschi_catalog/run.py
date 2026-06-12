"""Shared agent runner.

Thinking capture and tool progress are handled by the Hooks capability
from agent_hooks.build_progress_hooks(), which agents attach via
capabilities=[build_progress_hooks()].
"""

from __future__ import annotations

from pydantic_ai.usage import UsageLimits


async def run_agent(
    agent,
    prompt,
    deps,
    *,
    request_limit: int = 200,
    response_tokens_limit: int | None = None,
):
    """Run a pydantic-ai agent and return its structured output."""
    result = await agent.run(
        prompt,
        deps=deps,
        usage_limits=UsageLimits(
            request_limit=request_limit,
            response_tokens_limit=response_tokens_limit,
        ),
    )
    return result.output
