"""The audit leaves the singles a music artist's songs ship on alone.

Code ships a single when no album the artist ships has its song, which
it reads from every album's track list. The auditor sees the rule that
singles stay out and would take each one out again, so that override
is ignored. Any other finding on such a single is still the auditor's.
"""

from typing import Any

import pytest

from lauschi_catalog.catalog.audit_ops import AuditOverride, AuditResult, apply_audit
from lauschi_catalog.catalog.curate_ops import ONLY_RELEASE
from lauschi_catalog.catalog.lifecycle import open_flags
from tests.conftest import ScratchCatalog


@pytest.fixture
def senta(scratch_catalog: ScratchCatalog) -> ScratchCatalog:
    single: dict[str, Any] = {
        "album_id": "klaus",
        "provider": "spotify",
        "include": True,
        "title": "Senta Klaus",
        "confidence": "high",
        "decided_by": ONLY_RELEASE,
    }
    scratch_catalog.write_curation(
        {"id": "senta", "title": "Senta", "content_type": "music", "albums": [single]}
    )
    return scratch_catalog


@pytest.mark.parametrize(
    ("reason", "flagged"),
    [
        pytest.param("music_single", False, id="the rule the fact answers"),
        pytest.param("format_variant", True, id="another finding"),
    ],
)
def test_an_only_release_single_keeps_the_fact(
    senta: ScratchCatalog, reason: str, flagged: bool
) -> None:
    override = AuditOverride(
        album_id="klaus", provider="spotify", action="exclude", reason=reason
    )

    apply_audit("senta", AuditResult(approve=True, overrides=[override]))

    data = senta.read_curation("senta")
    assert data["albums"][0]["include"] is True
    assert bool(open_flags(data)) is flagged
    assert any(c.startswith("[only_release]") for c in data["review"]["concerns"]) is (
        not flagged
    )
