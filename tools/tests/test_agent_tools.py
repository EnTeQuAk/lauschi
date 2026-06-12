"""Tests for the shared agent FunctionToolset."""

from __future__ import annotations

import unittest

from lauschi_catalog.agent_tools import build_agent_tools


class TestBuildAgentTools(unittest.TestCase):
    def test_toolset_has_expected_tools(self) -> None:
        ts = build_agent_tools()
        assert set(ts.tools.keys()) == {"web_search", "fetch_page", "get_album_details"}

    def test_toolset_tools_take_context(self) -> None:
        ts = build_agent_tools()
        for name, tool in ts.tools.items():
            assert tool.function_schema.takes_ctx, f"{name} should take RunContext"
