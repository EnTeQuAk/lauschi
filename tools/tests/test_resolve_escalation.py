"""A person can approve an audit that escalated, after judging it.

Gemma escalates on its own false positives too: a reading it calls a
duplicate, an album it wants out against a person's call. Such an entry
used to stay escalated until a later audit happened to approve it.
`edit resolve` records who judged the audit and why, and the entry counts
as approved until its next curate or audit.
"""

from typing import Any

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog.audit_ops import AuditOverride, AuditResult, apply_audit
from lauschi_catalog.catalog.lifecycle import CurationState, apply_blockers, open_flags
from lauschi_catalog.commands.edit import edit
from tests.conftest import ScratchCatalog


def _curation() -> dict[str, Any]:
    return {
        "id": "s",
        "title": "S",
        "curated_at": "2026-11-18T10:00:00+00:00",
        "albums": [
            {
                "album_id": "a1",
                "provider": "spotify",
                "include": True,
                "title": "Das Traumfresserchen / Das kleine Lumpenkasperle",
                "confidence": "high",
            },
        ],
    }


def _audit(*, approve: bool) -> str:
    override = AuditOverride(
        album_id="a1", provider="spotify", action="exclude", reason="compilation"
    )
    return apply_audit("s", AuditResult(approve=approve, overrides=[override]))


@pytest.fixture
def escalated(scratch_catalog: ScratchCatalog) -> ScratchCatalog:
    scratch_catalog.write_curation(_curation())
    assert _audit(approve=False) == "escalated"
    return scratch_catalog


def _resolve(*args: str) -> Any:
    return CliRunner().invoke(edit, ["resolve", "s", *args])


def test_a_resolved_escalation_counts_as_approved(escalated: ScratchCatalog) -> None:
    result = _resolve("--note", "A different recording, 36 minutes against 46.")

    assert result.exit_code == 0, result.output
    data = escalated.read_curation("s")
    assert data["review"]["status"] == "approved"
    assert data["review"]["resolved"]["by"] == "operator"
    assert data["review"]["resolved"]["note"] == (
        "A different recording, 36 minutes against 46."
    )
    assert apply_blockers(CurationState.from_curation(data)) == []
    assert open_flags(data) == []
    assert data["albums"][0]["include"] is True


def test_a_later_audit_replaces_the_resolution(escalated: ScratchCatalog) -> None:
    _resolve("--note", "Judged by hand.")

    assert _audit(approve=False) == "escalated"
    review = escalated.read_curation("s")["review"]
    assert review["status"] == "escalated"
    assert "resolved" not in review


def test_only_an_escalated_entry_can_be_resolved(
    scratch_catalog: ScratchCatalog,
) -> None:
    scratch_catalog.write_curation(_curation())
    assert _audit(approve=True) == "flagged"

    result = _resolve("--note", "Nothing to judge.")

    assert result.exit_code == 1
    assert "not escalated" in result.output
    assert "resolved" not in scratch_catalog.read_curation("s")["review"]


def test_a_stale_audit_cannot_be_resolved(escalated: ScratchCatalog) -> None:
    """The person judges the audit of the curation as it stands."""
    data = escalated.read_curation("s")
    data["curated_at"] = "2099-01-01T00:00:00+00:00"
    escalated.write_curation(data)

    result = _resolve("--note", "Too late.")

    assert result.exit_code == 1
    assert "curate ran after the last audit" in result.output
    assert escalated.read_curation("s")["review"]["status"] == "escalated"


def test_a_resolution_needs_a_note(escalated: ScratchCatalog) -> None:
    result = _resolve()

    assert result.exit_code == 2
    assert escalated.read_curation("s")["review"]["status"] == "escalated"
