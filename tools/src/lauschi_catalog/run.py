"""Shared agent runner.

Thinking capture and tool progress are handled by the Hooks capability
from agent_hooks.build_progress_hooks(), which agents attach via
capabilities=[build_progress_hooks()].
"""

from typing import TYPE_CHECKING

from pydantic_ai import capture_run_messages
from pydantic_ai.usage import RunUsage, UsageLimits

if TYPE_CHECKING:
    pass


def usage_summary(usage: RunUsage) -> dict[str, int]:
    """The three numbers a cost estimate needs, as plain JSON."""
    return {
        "requests": usage.requests,
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
    }


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
