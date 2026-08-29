"""A failed audit must fail the process, or a pipeline records success."""

from __future__ import annotations

from types import SimpleNamespace

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog.audit_ops import AuditAllResult
from lauschi_catalog.commands import audit as audit_mod


def _wire(monkeypatch: pytest.MonkeyPatch, summary: AuditAllResult) -> None:
    async def fake_audit_series(series_ids, **kwargs):
        return summary

    monkeypatch.setattr(audit_mod, "audit_series", fake_audit_series)
    monkeypatch.setattr(
        audit_mod, "init_providers", lambda: SimpleNamespace(warnings=[], providers=[])
    )


def test_exits_nonzero_and_names_the_series_that_failed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _wire(monkeypatch, AuditAllResult(approved=1, failed=["benjamin_bluemchen"]))
    result = CliRunner().invoke(audit_mod.audit, ["-s", "benjamin_bluemchen"])
    assert result.exit_code == 1
    assert "1 series failed: benjamin_bluemchen" in result.output


def test_exits_zero_when_nothing_failed(monkeypatch: pytest.MonkeyPatch) -> None:
    _wire(monkeypatch, AuditAllResult(approved=1))
    result = CliRunner().invoke(audit_mod.audit, ["-s", "kira_kolumna"])
    assert result.exit_code == 0
