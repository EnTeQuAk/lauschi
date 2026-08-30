"""Shared agent runner.

Thinking capture and tool progress are handled by the Hooks capability
from agent_hooks.build_progress_hooks(), which agents attach via
capabilities=[build_progress_hooks()].
"""

from __future__ import annotations

from pydantic_ai.usage import RunUsage, UsageLimits


def usage_summary(usage: RunUsage) -> dict[str, int]:
    """The three numbers a cost estimate needs, as plain JSON."""
    return {
        "requests": usage.requests,
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
    }


async def run_with_attempts(
    make_call,
    *,
    attempts: int,
    label: str,
    on_progress,
):
    """Run ``make_call()`` up to ``attempts`` times, each from a fresh
    context, and return the first result.

    This is not the rate-limit retry (that one replays the same
    request). A model can fail a call on its own: reason its whole
    output budget away, omit half a batch, answer with nothing usable.
    Such a failure is usually specific to that one run, not to the
    prompt, so a fresh attempt tends to succeed where an in-run retry
    did not. The last failure is re-raised.
    """
    for attempt in range(1, attempts + 1):
        try:
            return await make_call()
        except Exception as exc:
            if attempt == attempts:
                raise
            on_progress(
                f"    {label} attempt {attempt}/{attempts} failed: "
                f"{type(exc).__name__}: {exc}. Retrying from a fresh context."
            )
    raise AssertionError("unreachable")


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
