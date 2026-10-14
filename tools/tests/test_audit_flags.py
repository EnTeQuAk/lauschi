"""An audit's overrides are flags for a person unless asked to apply them.

Gemma 4 audited two whole-catalog runs in 2026-10. Its escalations caught
every big slip, but its overrides went against the reviewed catalog about
two to one, and a sample read half wrong. So an approving audit keeps the
curator's decisions, records what it would change, and `catalog-review`
lists the series until a person has looked.
"""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog.audit_ops import AuditOverride, AuditResult, apply_audit
from lauschi_catalog.catalog.lifecycle import open_flags
from lauschi_catalog.commands.review_human import review_human


def _curation() -> dict:
    return {
        "id": "s",
        "title": "S",
        "episode_pattern": r"^Folge (\d+):",
        "albums": [
            {
                "album_id": "a1",
                "provider": "spotify",
                "include": True,
                "episode_num": 1,
                "title": "Folge 1: Der Anfang",
                "confidence": "high",
            },
            {
                "album_id": "a2",
                "provider": "spotify",
                "include": False,
                "title": "Die schönsten Lieder",
                "exclude_reason": "compilation",
            },
        ],
    }


def _override(album_id: str, action: str, reason: str = "r") -> AuditOverride:
    return AuditOverride(
        album_id=album_id, provider="spotify", action=action, reason=reason
    )


@pytest.fixture
def root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    curation_dir = tmp_path / "assets" / "catalog" / "curation"
    curation_dir.mkdir(parents=True)
    (curation_dir / "s.json").write_text(json.dumps(_curation()))
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    return tmp_path


def _read(root: Path) -> dict:
    return json.loads((root / "assets/catalog/curation/s.json").read_text())


def test_an_approving_audit_flags_an_override_and_changes_no_album(root: Path) -> None:
    result = AuditResult(
        approve=True,
        overrides=[_override("a1", "exclude", "a reading, not an episode")],
    )
    action = apply_audit("s", result, model_name="critic")
    data = _read(root)
    a1 = data["albums"][0]
    assert action == "flagged"
    assert data["review"]["status"] == "approved"
    assert a1["include"] is True
    assert "decided_by" not in a1
    assert data["review"]["overrides"][0]["album_id"] == "a1"
    assert any(
        c.startswith("[flag] spotify:a1") and "Folge 1: Der Anfang" in c
        for c in data["review"]["concerns"]
    )
    assert [f["album_id"] for f in open_flags(data)] == ["a1"]


def test_an_override_that_flips_nothing_is_no_flag(root: Path) -> None:
    """Naming another reason for an excluded album changes what nobody sees."""
    result = AuditResult(approve=True, overrides=[_override("a2", "exclude")])
    assert apply_audit("s", result, model_name="critic") == "approved"
    assert open_flags(_read(root)) == []


def test_apply_overrides_keeps_the_auditor_deciding(root: Path) -> None:
    result = AuditResult(approve=True, overrides=[_override("a1", "exclude")])
    action = apply_audit("s", result, model_name="critic", apply_overrides=True)
    data = _read(root)
    assert action == "overridden"
    assert data["albums"][0]["include"] is False
    assert data["albums"][0]["decided_by"] == "critic"
    assert open_flags(data) == []


def test_too_many_flags_still_escalate(root: Path) -> None:
    """The volume rule is about how far the auditor disagrees, which is a
    signal whether or not its overrides are applied."""
    data = _curation()
    data["albums"] = [
        {
            "album_id": f"a{i}",
            "provider": "spotify",
            "include": True,
            "episode_num": i,
            "title": f"Folge {i}: Titel {i}",
        }
        for i in range(1, 21)
    ]
    (root / "assets/catalog/curation/s.json").write_text(json.dumps(data))
    overrides = [_override(f"a{i}", "exclude") for i in range(1, 8)]
    result = AuditResult(approve=True, overrides=overrides)
    assert apply_audit("s", result, model_name="critic") == "escalated"


def test_a_decision_by_hand_settles_a_flag(root: Path) -> None:
    apply_audit(
        "s",
        AuditResult(approve=True, overrides=[_override("a1", "exclude")]),
        model_name="critic",
    )
    data = _read(root)
    data["albums"][0].update(decided_by="operator", decided_at="2999-01-01T00:00:00")
    assert open_flags(data) == []


def test_only_the_latest_audit_raises_flags(root: Path) -> None:
    """The overrides list keeps every round's entries. A flag the next
    audit no longer raises is not open any more."""
    apply_audit(
        "s",
        AuditResult(approve=True, overrides=[_override("a1", "exclude")]),
        model_name="critic",
    )
    apply_audit("s", AuditResult(approve=True), model_name="critic")
    data = _read(root)
    assert [o["album_id"] for o in data["review"]["overrides"]] == ["a1"]
    assert open_flags(data) == []


def test_review_lists_a_flagged_series_with_its_flags(root: Path) -> None:
    apply_audit(
        "s",
        AuditResult(approve=True, overrides=[_override("a1", "exclude", "a reading")]),
        model_name="critic",
    )
    out = CliRunner().invoke(review_human, ["-d"], terminal_width=200)
    assert out.exit_code == 0, out.output
    assert "flagged" in out.output
    assert "Folge 1: Der Anfang" in out.output
    assert "a reading" in out.output
