from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic_ai.messages import (
    ModelRequest,
    ModelResponse,
    RetryPromptPart,
    TextPart,
    UserPromptPart,
)

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import dump_batch_failure


@pytest.fixture
def log_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(curate_ops, "log_dir", lambda: tmp_path / "logs")
    return tmp_path / "logs"


def test_the_exchange_and_the_reason_are_written_next_to_the_prompt(
    log_dir: Path,
) -> None:
    messages = [
        ModelRequest(parts=[UserPromptPart(content="Batch 3/12 (30 albums)")]),
        ModelResponse(parts=[TextPart(content="{...29 albums...}")]),
        ModelRequest(
            parts=[RetryPromptPart(content="You omitted 1 album(s) from your output.")]
        ),
    ]
    try:
        raise RuntimeError("Exceeded maximum output retries (2)")
    except RuntimeError as exc:
        path = dump_batch_failure("fuenf_freunde", 3, "Batch 3/12 ...", messages, exc)

    assert path == log_dir / "curate-failures" / "fuenf_freunde-batch03.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data["series_id"] == "fuenf_freunde"
    assert data["batch"] == 3
    assert data["error"] == "RuntimeError: Exceeded maximum output retries (2)"
    assert data["prompt"] == "Batch 3/12 ..."
    kinds = [m["kind"] for m in data["messages"]]
    assert kinds == ["request", "response", "request"]
    assert data["messages"][2]["parts"][0]["part_kind"] == "retry-prompt"


def test_a_second_failure_of_the_same_batch_overwrites_the_first(log_dir: Path) -> None:
    exc = RuntimeError("x")
    dump_batch_failure("s", 1, "first", [], exc)
    path = dump_batch_failure("s", 1, "second", [], exc)
    assert json.loads(path.read_text())["prompt"] == "second"
    assert len(list((log_dir / "curate-failures").iterdir())) == 1
