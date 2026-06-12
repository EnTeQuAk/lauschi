"""Tests for the shared agent progress hooks."""

from __future__ import annotations

import asyncio
import unittest
from typing import Any
from unittest.mock import MagicMock

from pydantic_ai.capabilities.hooks import Hooks
from pydantic_ai.messages import ModelResponse, ThinkingPart, TextPart
from pydantic_ai.models import ModelRequestContext

from lauschi_catalog.agent_hooks import build_progress_hooks


class TestBuildProgressHooks(unittest.TestCase):
    def test_returns_hooks_instance(self) -> None:
        hooks = build_progress_hooks()
        assert isinstance(hooks, Hooks)

    def test_hooks_have_registered_handlers(self) -> None:
        hooks = build_progress_hooks()
        registry = hooks._registry
        assert "after_model_request" in registry
        assert "after_tool_execute" in registry


class TestThinkingCaptureHook(unittest.TestCase):
    """Test the after_model_request hook that captures thinking parts."""

    def _run(self, coro: Any) -> Any:
        return asyncio.new_event_loop().run_until_complete(coro)

    def _make_ctx(self) -> MagicMock:
        ctx = MagicMock()
        ctx.deps.on_progress = MagicMock()
        return ctx

    def _get_thinking_hook(self, hooks: Hooks) -> Any:
        entries = hooks._registry.get("after_model_request", [])
        assert len(entries) == 1, (
            f"Expected 1 after_model_request hook, got {len(entries)}"
        )
        return entries[0].func

    def test_forwards_long_thinking_snippets(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_thinking_hook(hooks)
        ctx = self._make_ctx()
        long_thought = "x" * 100
        response = ModelResponse(parts=[ThinkingPart(content=long_thought)])
        req_ctx = MagicMock(spec=ModelRequestContext)

        result = self._run(hook(ctx, request_context=req_ctx, response=response))

        assert result is response
        ctx.deps.on_progress.assert_called_once()
        msg = ctx.deps.on_progress.call_args[0][0]
        assert "[reasoning]" in msg
        assert "x" * 100 in msg

    def test_skips_short_thinking_snippets(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_thinking_hook(hooks)
        ctx = self._make_ctx()
        short_thought = "brief"
        response = ModelResponse(parts=[ThinkingPart(content=short_thought)])
        req_ctx = MagicMock(spec=ModelRequestContext)

        self._run(hook(ctx, request_context=req_ctx, response=response))
        ctx.deps.on_progress.assert_not_called()

    def test_truncates_thinking_to_500_chars(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_thinking_hook(hooks)
        ctx = self._make_ctx()
        long_thought = "a" * 1000
        response = ModelResponse(parts=[ThinkingPart(content=long_thought)])
        req_ctx = MagicMock(spec=ModelRequestContext)

        self._run(hook(ctx, request_context=req_ctx, response=response))
        msg = ctx.deps.on_progress.call_args[0][0]
        # "[reasoning] " prefix + 500 chars
        assert len(msg) == len("  [reasoning] ") + 500

    def test_ignores_text_parts(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_thinking_hook(hooks)
        ctx = self._make_ctx()
        response = ModelResponse(parts=[TextPart(content="just text")])
        req_ctx = MagicMock(spec=ModelRequestContext)

        self._run(hook(ctx, request_context=req_ctx, response=response))
        ctx.deps.on_progress.assert_not_called()

    def test_skips_when_no_on_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_thinking_hook(hooks)
        ctx = MagicMock()
        del ctx.deps.on_progress
        long_thought = "x" * 100
        response = ModelResponse(parts=[ThinkingPart(content=long_thought)])
        req_ctx = MagicMock(spec=ModelRequestContext)

        result = self._run(hook(ctx, request_context=req_ctx, response=response))
        assert result is response


class TestToolProgressHook(unittest.TestCase):
    """Test the after_tool_execute hook that reports tool completion."""

    def _run(self, coro: Any) -> Any:
        return asyncio.new_event_loop().run_until_complete(coro)

    def _make_ctx(self) -> MagicMock:
        ctx = MagicMock()
        ctx.deps.on_progress = MagicMock()
        return ctx

    def _make_call(self, tool_name: str) -> MagicMock:
        call = MagicMock()
        call.tool_name = tool_name
        return call

    def _get_tool_hook(self, hooks: Hooks) -> Any:
        entries = hooks._registry.get("after_tool_execute", [])
        assert len(entries) == 1, (
            f"Expected 1 after_tool_execute hook, got {len(entries)}"
        )
        return entries[0].func

    def test_web_search_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_tool_hook(hooks)
        ctx = self._make_ctx()
        call = self._make_call("web_search")
        args = {"query": "bibi und tina"}
        result = [{"title": "a"}, {"title": "b"}, {"error": "fail"}]
        tool_def = MagicMock()

        ret = self._run(
            hook(ctx, call=call, tool_def=tool_def, args=args, result=result)
        )
        assert ret is result
        msg = ctx.deps.on_progress.call_args[0][0]
        assert "web_search" in msg
        assert "bibi und tina" in msg
        assert "2 results" in msg

    def test_fetch_page_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_tool_hook(hooks)
        ctx = self._make_ctx()
        call = self._make_call("fetch_page")
        args = {"url": "https://example.com/some/page"}
        result = "page content here"
        tool_def = MagicMock()

        self._run(hook(ctx, call=call, tool_def=tool_def, args=args, result=result))
        msg = ctx.deps.on_progress.call_args[0][0]
        assert "fetch_page" in msg
        assert "example.com" in msg
        assert "17 chars" in msg

    def test_get_album_details_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_tool_hook(hooks)
        ctx = self._make_ctx()
        call = self._make_call("get_album_details")
        args = {"provider": "spotify", "album_ids": ["a", "b", "c"]}
        result = [{"id": "a"}, {"id": "b"}]
        tool_def = MagicMock()

        self._run(hook(ctx, call=call, tool_def=tool_def, args=args, result=result))
        msg = ctx.deps.on_progress.call_args[0][0]
        assert "get_album_details" in msg
        assert "spotify" in msg
        assert "3 ids" in msg
        assert "2 results" in msg

    def test_unknown_tool_no_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_tool_hook(hooks)
        ctx = self._make_ctx()
        call = self._make_call("some_other_tool")
        tool_def = MagicMock()

        self._run(hook(ctx, call=call, tool_def=tool_def, args={}, result="ok"))
        ctx.deps.on_progress.assert_not_called()

    def test_skips_when_no_on_progress(self) -> None:
        hooks = build_progress_hooks()
        hook = self._get_tool_hook(hooks)
        ctx = MagicMock()
        del ctx.deps.on_progress
        call = self._make_call("web_search")
        tool_def = MagicMock()

        ret = self._run(
            hook(ctx, call=call, tool_def=tool_def, args={"query": "q"}, result=[])
        )
        assert ret == []
