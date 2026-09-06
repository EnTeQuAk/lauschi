"""Tests for the shared agent FunctionToolset."""

import unittest
from types import SimpleNamespace

from lauschi_catalog.agent_deps import AgentDeps
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.reference import ReferenceIndex
from tests.test_reference_index import fake_fetch


class TestBuildAgentTools(unittest.TestCase):
    def test_toolset_has_expected_tools(self) -> None:
        ts = build_agent_tools()
        assert set(ts.tools.keys()) == {
            "web_search",
            "fetch_page",
            "get_album_details",
            "lookup_reference_lines",
        }

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


class TestReferenceLookup(unittest.TestCase):
    def _ctx(self, index: ReferenceIndex | None) -> SimpleNamespace:
        deps = AgentDeps()
        deps.reference = index
        return SimpleNamespace(deps=deps)

    def test_an_unconfigured_index_is_reported_not_raised(self) -> None:
        tool = build_agent_tools().tools["lookup_reference_lines"].function
        result = tool(self._ctx(ReferenceIndex("", fetch=fake_fetch)), "TKKG")
        assert "not configured" in result["error"]

    def test_a_brand_comes_back_as_lines_of_titles_without_numbers(self) -> None:
        tool = build_agent_tools().tools["lookup_reference_lines"].function
        index = ReferenceIndex(
            "https://example.test/api", fetch=fake_fetch, use_cache=False
        )
        result = tool(self._ctx(index), "Kommissar Kugelblitz")
        assert result["series"] == "Kommissar Kugelblitz"
        assert result["lines"][0]["name"] == "Hörspiele zu den Büchern"
        assert result["lines"][0]["titles"] == ["Die rote Socke", "Sammelband"]
        assert "number" not in str(result), "numbers never come from the index"

    def test_lookups_past_the_budget_return_the_limit(self) -> None:
        tool = build_agent_tools().tools["lookup_reference_lines"].function
        ctx = self._ctx(None)
        ctx.deps._reference_count = AgentDeps._MAX_REFERENCE_CALLS
        assert tool(ctx, "TKKG") == {
            "error": "Reference lookup limit reached (5). Decide with what you have."
        }
