"""Shared agent runner.

Thinking capture and tool progress are handled by the Hooks capability
from agent_hooks.build_progress_hooks(), which agents attach via
capabilities=[build_progress_hooks()].
"""

from __future__ import annotations

from pydantic_ai.usage import RunUsage, UsageLimits


async def run_agent(
    agent,
    prompt,
    deps,
    *,
    request_limit: int = 200,
    response_tokens_limit: int | None = None,
    tally: RunUsage | None = None,
):
    """Run a pydantic-ai agent and return its structured output.

    ``tally`` accumulates the run's requests and tokens, so a caller
    that runs many agents for one piece of work can report what it
    cost.
    """
    result = await agent.run(
        prompt,
        deps=deps,
        usage_limits=UsageLimits(
            request_limit=request_limit,
            response_tokens_limit=response_tokens_limit,
        ),
    )
    if tally is not None:
        tally.incr(result.usage)
    return result.output
