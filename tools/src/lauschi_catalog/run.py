"""Shared agent runner.

Thinking capture and tool progress are handled by the Hooks capability
from agent_hooks.build_progress_hooks(), which agents attach via
capabilities=[build_progress_hooks()].
"""

from typing import Literal

from pydantic_ai import capture_run_messages
from pydantic_ai.usage import RunUsage, UsageLimits

# What happens to a function tool the model sends together with its final
# answer. pydantic-ai's default, 'graceful', runs it. Our tools write state
# the run reads back afterwards (the finalize agent's pattern and facts),
# and the model never sees their reply in that case, so the first valid
# output ends the run and the tools next to it are skipped.
END_STRATEGY: Literal["early"] = "early"


def usage_summary(usage: "RunUsage | dict[str, int]") -> dict[str, int]:
    """The three numbers a cost estimate needs, as plain JSON.

    Idempotent: passing an already-summarised dict returns it, so a
    call site that hands over a persisted usage dict cannot crash.
    """
    if isinstance(usage, dict):
        return {
            "requests": usage.get("requests", 0),
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
        }
    return {
        "requests": usage.requests,
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
    }


def usage_delta(before: dict[str, int], after: dict[str, int]) -> dict[str, int]:
    """What was spent between two usage summaries of one tally."""
    return {k: after.get(k, 0) - before.get(k, 0) for k in after}


OnFailure = "Callable[[int, BaseException, list[ModelMessage]], None]"


async def run_with_attempts(
    make_call,
    *,
    attempts: int,
    label: str,
    on_progress,
    on_failure: OnFailure | None = None,  # type: ignore[valid-type]
):
    """Run ``make_call()`` up to ``attempts`` times, each from a fresh
    context, and return the first result.

    This is not the rate-limit retry (that one replays the same
    request). A model can fail a call on its own: reason its whole
    output budget away, omit half a batch, answer with nothing usable.
    Such a failure is usually specific to that one run, not to the
    prompt, so a fresh attempt tends to succeed where an in-run retry
    did not. The last failure is re-raised; the caller decides what a
    lost call means.

    ``on_failure(attempt, exc, messages)`` fires on every failure with
    the exchange captured for that attempt, so callers can persist the
    evidence immediately (dumping it after the loop only works when a
    helper tracks the last exchange itself).
    """
    for attempt in range(1, attempts + 1):
        with capture_run_messages() as messages:
            try:
                return await make_call()
            except Exception as exc:
                on_progress(
                    f"    {label} attempt {attempt}/{attempts} failed: "
                    f"{type(exc).__name__}: {exc}. Retrying from a fresh context."
                )
                if on_failure is not None:
                    on_failure(attempt, exc, list(messages))
                if attempt == attempts:
                    raise
    raise AssertionError("unreachable")


async def run_agent(
    agent,
    prompt,
    deps,
    *,
    request_limit: int = 200,
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
        usage_limits=UsageLimits(request_limit=request_limit),
    )
    if tally is not None:
        tally.incr(result.usage)
    return result.output
