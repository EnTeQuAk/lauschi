"""TestModel-based tests for agent construction and wiring.

Verifies that each agent has the right tools, hooks, and output types,
and can complete a run with TestModel. Tool behavior and output validators
are tested separately in test_curate_helpers.py and test_agent_hooks.py.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from pydantic_ai.capabilities.hooks import Hooks
from pydantic_ai.models.test import TestModel

from lauschi_catalog.catalog.audit_ops import (
    AuditDeps,
    AuditResult,
    _build_audit_agent,
)
from lauschi_catalog.catalog.curate_ops import (
    BatchResult,
    CurateDeps,
    FinalizeResult,
    SeriesMetadata,
    _build_batch_agent,
    _build_finalize_agent,
    _build_metadata_agent,
)
from lauschi_catalog.run import run_agent


def _agent_tool_names(agent: Any) -> set[str]:
    names: set[str] = set()
    for ts in agent.toolsets:
        if hasattr(ts, "tools"):
            names.update(ts.tools.keys())
    return names


def _run(coro: Any) -> Any:
    return asyncio.new_event_loop().run_until_complete(coro)


# ── Audit agent construction (not covered in test_curate_helpers) ─────────


class TestAuditAgentWiring:
    def test_has_shared_tools(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            "lauschi_catalog.catalog.audit_ops.build_model",
            lambda name, key: TestModel(),
        )
        agent = _build_audit_agent("test", "fake-key")
        names = _agent_tool_names(agent)
        assert "web_search" in names
        assert "fetch_page" in names
        assert "get_album_details" in names

    def test_has_audit_specific_tools(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            "lauschi_catalog.catalog.audit_ops.build_model",
            lambda name, key: TestModel(),
        )
        agent = _build_audit_agent("test", "fake-key")
        names = _agent_tool_names(agent)
        assert "search_included_albums" in names
        assert "lint_current_curation" in names

    def test_has_progress_hooks(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            "lauschi_catalog.catalog.audit_ops.build_model",
            lambda name, key: TestModel(),
        )
        agent = _build_audit_agent("test", "fake-key")
        hooks_caps = [
            c for c in agent.root_capability.capabilities if isinstance(c, Hooks)
        ]
        assert len(hooks_caps) == 1
        registry = hooks_caps[0]._registry
        assert "after_model_request" in registry
        assert "after_tool_execute" in registry

    def test_uses_submit_audit_tool_output(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        from pydantic_ai import ToolOutput

        monkeypatch.setattr(
            "lauschi_catalog.catalog.audit_ops.build_model",
            lambda name, key: TestModel(),
        )
        agent = _build_audit_agent("test", "fake-key")
        assert isinstance(agent.output_type, ToolOutput)
        assert agent.output_type.name == "submit_audit"


# ── Agent runs with TestModel ─────────────────────────────────────────────


class TestAgentRuns:
    """Each agent completes a run with TestModel and produces the right type.

    Uses content_type="music" for metadata (no output validator requiring
    check_pattern_coverage calls) and empty deps to avoid side effects.
    """

    def test_metadata_agent_run(self) -> None:
        model = TestModel(call_tools=[])
        agent = _build_metadata_agent(model, content_type="music")
        deps = CurateDeps()
        result = agent.run_sync("Extract metadata", deps=deps)
        assert isinstance(result.output, SeriesMetadata)

    def test_batch_agent_run(self) -> None:
        agent = _build_batch_agent(TestModel(call_tools=[]))
        deps = CurateDeps()
        result = agent.run_sync("Process this batch", deps=deps)
        assert isinstance(result.output, BatchResult)

    def test_finalize_agent_run(self) -> None:
        agent = _build_finalize_agent(TestModel(call_tools=[]))
        deps = CurateDeps()
        result = agent.run_sync("Finalize the curation", deps=deps)
        assert isinstance(result.output, FinalizeResult)

    def test_audit_agent_run(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(
            "lauschi_catalog.catalog.audit_ops.build_model",
            lambda name, key: TestModel(call_tools=[]),
        )
        agent = _build_audit_agent("test", "fake-key")
        deps = AuditDeps(
            curation={"id": "test", "title": "Test", "albums": []},
        )
        result = agent.run_sync("Audit this series", deps=deps)
        assert isinstance(result.output, AuditResult)


# ── run_agent integration ─────────────────────────────────────────────────


class TestRunAgent:
    """Verify the run_agent helper works end-to-end with TestModel."""

    def test_returns_output_directly(self) -> None:
        agent = _build_finalize_agent(TestModel(call_tools=[]))
        deps = CurateDeps()
        output = _run(run_agent(agent, "Finalize", deps))
        assert isinstance(output, FinalizeResult)

    def test_respects_request_limit(self) -> None:
        agent = _build_batch_agent(TestModel(call_tools=[]))
        deps = CurateDeps()
        output = _run(run_agent(agent, "Batch", deps, request_limit=5))
        assert isinstance(output, BatchResult)
