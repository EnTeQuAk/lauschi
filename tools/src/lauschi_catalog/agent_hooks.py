"""Shared progress hooks for pipeline agents.

Builds a Hooks capability that reports agent activity via
deps.on_progress. Captures two things:

1. Thinking snippets from model responses (>80 chars, truncated to 500)
2. One line per tool call: a summary for web_search, fetch_page and
   get_album_details, the arguments and result size for any other tool

Agents attach this via capabilities=[build_progress_hooks()].
"""

from typing import Any

from pydantic_ai import RunContext
from pydantic_ai.capabilities.hooks import Hooks
from pydantic_ai.messages import ModelResponse, ThinkingPart, ToolCallPart
from pydantic_ai.models import ModelRequestContext
from pydantic_ai.tools import ToolDefinition

_SHARED_TOOLS = {"web_search", "fetch_page", "get_album_details"}


def build_progress_hooks() -> Hooks:
    """Build hooks that report agent progress via deps.on_progress."""
    hooks = Hooks()

    @hooks.on.after_model_request
    async def capture_thinking(
        ctx: RunContext[Any],
        /,
        *,
        request_context: ModelRequestContext,
        response: ModelResponse,
    ) -> ModelResponse:
        on_progress = getattr(ctx.deps, "on_progress", None)
        if not on_progress:
            return response
        for part in response.parts:
            if not isinstance(part, ThinkingPart):
                continue
            content = part.content.strip()
            if len(content) > 80:
                on_progress(f"  [reasoning] {content[:500]}")
        return response

    @hooks.on.after_tool_execute
    async def report_tool_call(
        ctx: RunContext[Any],
        /,
        *,
        call: ToolCallPart,
        tool_def: ToolDefinition,
        args: dict[str, Any],
        result: Any,
    ) -> Any:
        on_progress = getattr(ctx.deps, "on_progress", None)
        if not on_progress:
            return result
        msg = _format_tool_progress(call.tool_name, args, result)
        if msg:
            on_progress(msg)
        return result

    return hooks


def _format_tool_progress(name: str, args: dict[str, Any], result: Any) -> str | None:
    if name == "web_search":
        query = args.get("query", "?")
        if isinstance(result, list):
            errors = [r.get("error") for r in result if "error" in r]
            n = len(result) - len(errors)
            if errors:
                return f"  web_search({query!r}) -> {n} results, error: {errors[0]}"
            return f"  web_search({query!r}) -> {n} results"
        return f"  web_search({query!r}) -> ? results"

    if name == "fetch_page":
        url = str(args.get("url", "?"))[:60]
        return f"  fetch_page({url}) -> {len(result)} chars"

    if name == "get_album_details":
        provider = args.get("provider", "?")
        ids = args.get("album_ids", [])
        n = len(result) if isinstance(result, list) else "?"
        return f"  get_album_details({provider}, {len(ids)} ids) -> {n} results"

    shown = ", ".join(f"{k}={v!r}" for k, v in args.items())
    if len(shown) > 100:
        shown = shown[:97] + "..."
    return f"  {name}({shown}) -> {_result_size(result)}"


def _result_size(result: Any) -> str:
    if isinstance(result, list | tuple | dict):
        return f"{len(result)} results"
    if isinstance(result, str):
        return f"{len(result)} chars"
    return repr(result)[:60]
