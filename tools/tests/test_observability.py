"""Agent runs are traced to Logfire when the checkout has a credential.

A curation run makes dozens of model requests and tool calls. Until now
the only record was a progress transcript. With a Logfire credential in
`.logfire/` every run, request and tool call becomes a span, labelled
with the agent that made it. Without one nothing is sent and nobody is
asked to log in.
"""

import asyncio
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import logfire
import pytest
from logfire.testing import CaptureLogfire
from pydantic_ai import Agent
from pydantic_ai.messages import ModelMessage, ModelResponse, ToolCallPart
from pydantic_ai.models.function import AgentInfo, FunctionModel
from pydantic_ai.models.test import TestModel

from lauschi_catalog import observability
from lauschi_catalog.catalog.audit_ops import _build_audit_agent
from lauschi_catalog.catalog.curate_ops import (
    CurateDeps,
    _build_batch_agent,
    _build_finalize_agent,
    _build_metadata_agent,
)


@pytest.fixture
def untraced_afterwards() -> Iterator[None]:
    """Instrumentation is process-wide, so a test that turns it on turns
    it off again for the tests that follow."""
    yield
    Agent.instrument_all(False)
    logfire.configure(send_to_logfire=False, console=False)


@pytest.mark.parametrize(
    ("build", "name"),
    [
        (_build_metadata_agent, "curate_metadata"),
        (_build_batch_agent, "curate_batch"),
        (_build_finalize_agent, "curate_finalize"),
        (_build_audit_agent, "audit"),
    ],
)
def test_every_agent_has_a_name(build: Any, name: str) -> None:
    """The name labels the agent's runs. Without one every run is "agent"
    and the four phases cannot be told apart."""
    assert build(TestModel()).name == name


def test_a_batch_run_is_traced_under_its_agents_name(
    capfire: CaptureLogfire, untraced_afterwards: None
) -> None:
    def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        return ModelResponse(
            parts=[ToolCallPart(info.output_tools[0].name, {"albums": []})]
        )

    logfire.instrument_pydantic_ai()
    agent = _build_batch_agent(FunctionModel(respond))
    asyncio.run(agent.run("batch", deps=CurateDeps(pattern=None, all_decisions=[])))

    spans = [span["name"] for span in capfire.exporter.exported_spans_as_dict()]
    assert "invoke_agent curate_batch" in spans


def test_without_a_credential_nothing_is_sent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, untraced_afterwards: None
) -> None:
    """A checkout without `.logfire/` credentials runs as before: no
    token, no login prompt, no error."""
    monkeypatch.delenv("LOGFIRE_TOKEN", raising=False)
    monkeypatch.setattr(observability, "checkout_root", lambda: tmp_path)

    observability.configure_observability()

    config = logfire.DEFAULT_LOGFIRE_INSTANCE.config
    assert config.send_to_logfire == "if-token-present"
    assert not config.token
    assert config.service_name == "lauschi-catalog"
