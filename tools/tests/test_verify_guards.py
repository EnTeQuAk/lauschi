"""Tests for verify_one's pre-flight guards.

verify_one is async and instantiates an Agent against the live
opencode endpoint, so we don't drive the agent itself here. We do
exercise the guards that decide whether the agent runs at all —
those gate which curations reach the LLM and matter for both budget
and pipeline correctness.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest

from lauschi_catalog.commands import verify as verify_mod
from lauschi_catalog.commands.verify import verify_one


@pytest.fixture
def curation_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(verify_mod, "CURATION_DIR", tmp_path)
    # Stub out the API key check so we get to the guard, not past it.
    monkeypatch.setenv("OPENCODE_API_KEY", "test")
    return tmp_path


def _write(path: Path, sid: str, data: dict[str, Any]) -> Path:
    p = path / f"{sid}.json"
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return p


def test_verify_one_skips_curation_without_review_block(curation_dir: Path):
    """Fresh curations (review never ran) must not reach the verify agent.

    An empty review block has nothing to verify — running the model
    against it wastes budget and produces meaningless output.
    """
    _write(curation_dir, "s1", {
        "id": "s1", "title": "Test", "albums": [],
    })
    result = asyncio.run(verify_one("s1", providers=[]))
    assert result is None


def test_verify_one_skips_empty_review_block_even_with_force(curation_dir: Path):
    """--force should not bypass the empty-review guard.

    Force is for re-running verification despite an existing approved
    status — not for verifying a curation that was never reviewed.
    """
    _write(curation_dir, "s1", {
        "id": "s1", "title": "Test", "albums": [], "review": {},
    })
    result = asyncio.run(verify_one("s1", providers=[], force=True))
    assert result is None


def test_verify_one_returns_none_when_curation_file_missing(curation_dir: Path):
    result = asyncio.run(verify_one("nonexistent", providers=[]))
    assert result is None
