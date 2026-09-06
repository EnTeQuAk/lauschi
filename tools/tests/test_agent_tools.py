"""Tests for the shared agent FunctionToolset."""

import unittest
from types import SimpleNamespace

from lauschi_catalog.agent_deps import AgentDeps
from lauschi_catalog.agent_tools import build_agent_tools


class TestBuildAgentTools(unittest.TestCase):
    def test_toolset_has_expected_tools(self) -> None:
        ts = build_agent_tools()
        assert set(ts.tools.keys()) == {"web_search", "fetch_page", "get_album_details"}

    def test_toolset_tools_take_context(self) -> None:
        ts = build_agent_tools()
        for name, tool in ts.tools.items():
            assert tool.function_schema.takes_ctx, f"{name} should take RunContext"


class TestBudgetExhaustion(unittest.TestCase):
    """An exhausted tool budget is an answer, not a malformed call.

    Raising ModelRetry on every call past the budget counts against
    pydantic-ai's per-tool retry cap, so the third call past the budget
    killed the whole run (Wieso? Weshalb? Warum? audit, chunk 7,
    2026-09-06: "Tool 'get_album_details' exceeded max retries count of
    2"). The tools now return the limit message as a result and the
    model carries on with what it has.
    """

    def _ctx(self, **spent: int) -> SimpleNamespace:
        deps = AgentDeps()
        for name, value in spent.items():
            setattr(deps, name, value)
        return SimpleNamespace(deps=deps)

    def test_details_past_the_budget_return_the_limit_as_a_result(self) -> None:
        tool = build_agent_tools().tools["get_album_details"].function
        ctx = self._ctx(_detail_count=AgentDeps._MAX_DETAIL_CALLS)
        result = tool(ctx, "spotify", ["4KFElrzg5yWmppwtZ84UzG"])
        assert result == [
            {"error": "Detail fetch limit reached (40). Decide with what you have."}
        ]
        assert ctx.deps._detail_count == AgentDeps._MAX_DETAIL_CALLS

    def test_search_past_the_budget_returns_the_limit_as_a_result(self) -> None:
        tool = build_agent_tools().tools["web_search"].function
        result = tool(
            self._ctx(_search_count=AgentDeps._MAX_SEARCHES), "Kira Kolumna Folge 28"
        )
        assert result == [
            {"error": "Search limit reached (3). Decide with what you have."}
        ]

    def test_fetch_past_the_budget_returns_the_limit_as_a_result(self) -> None:
        tool = build_agent_tools().tools["fetch_page"].function
        result = tool(
            self._ctx(_fetch_count=AgentDeps._MAX_FETCHES), "https://example.org"
        )
        assert result == "Fetch limit reached (2). Decide with what you have."
