"""Shared agent runner with streaming reasoning output."""

from __future__ import annotations

from pydantic_ai import CallToolsNode
from pydantic_ai.messages import ThinkingPart
from pydantic_ai.usage import UsageLimits
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel

console = Console()


async def run_agent_streaming(agent, prompt, deps, *, request_limit: int = 200):
    """Run a pydantic-ai agent, streaming thinking parts to the console.

    Returns the agent's structured output. Thinking fragments longer
    than 80 chars are shown in a dim Rich panel; shorter ones are
    skipped to keep the output readable.
    """
    async with agent.iter(
        prompt, deps=deps,
        usage_limits=UsageLimits(request_limit=request_limit),
    ) as run:
        async for node in run:
            if not isinstance(node, CallToolsNode):
                continue
            for part in node.model_response.parts:
                if not isinstance(part, ThinkingPart):
                    continue
                if len(part.content.strip()) <= 80:
                    continue
                safe = escape(part.content.strip()[:500])
                try:
                    console.print(
                        Panel(
                            safe,
                            border_style="dim",
                            title="💭 reasoning",
                            padding=(0, 1),
                        ),
                    )
                except Exception:
                    pass
        return run.result.output
