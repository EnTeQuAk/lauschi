"""The audit records what it cost, next to who audited and when."""

import asyncio
import json
from pathlib import Path

import pytest
from pydantic_ai.usage import RunUsage

import lauschi_catalog.catalog.audit_ops as m
from lauschi_catalog.catalog.audit_ops import AuditResult, apply_audit, audit_series


@pytest.fixture
def curation_file(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    curation_dir = tmp_path / "assets" / "catalog" / "curation"
    curation_dir.mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    path = curation_dir / "s.json"
    path.write_text(
        json.dumps(
            {
                "id": "s",
                "title": "S",
                "albums": [
                    {
                        "album_id": "a1",
                        "provider": "spotify",
                        "include": True,
                        "episode_num": 1,
                        "title": "Folge 1",
                        "confidence": "high",
                    }
                ],
            }
        )
    )
    return path


def test_apply_audit_writes_the_usage_into_the_review_block(
    curation_file: Path,
) -> None:
    usage = {"requests": 3, "input_tokens": 9000, "output_tokens": 800}
    apply_audit("s", AuditResult(approve=True), model_name="kimi-k3", usage=usage)
    review = json.loads(curation_file.read_text())["review"]
    assert review["audited_by"] == "kimi-k3"
    assert review["usage"] == usage


def test_apply_audit_without_usage_leaves_the_block_alone(curation_file: Path) -> None:
    apply_audit("s", AuditResult(approve=True), model_name="kimi-k3")
    assert "usage" not in json.loads(curation_file.read_text())["review"]


def test_audit_series_passes_the_tally_through_to_the_review(
    curation_file: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def fake_audit_one(sid, *, usage=None, **kw):
        assert usage is not None
        usage.incr(RunUsage(requests=2, input_tokens=7000, output_tokens=500))
        return AuditResult(approve=True)

    monkeypatch.setattr(m, "audit_one", fake_audit_one)
    progress: list[str] = []
    summary = asyncio.run(
        audit_series(["s"], model_name="kimi-k3", on_progress=progress.append)
    )
    assert summary.approved == 1
    review = json.loads(curation_file.read_text())["review"]
    assert review["usage"] == {
        "requests": 2,
        "input_tokens": 7000,
        "output_tokens": 500,
    }
    assert any("Usage: 2 requests, 7000 in / 500 out tokens" in p for p in progress)
