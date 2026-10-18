"""An audit's overrides are flags for a person unless asked to apply them.

Gemma 4 audited two whole-catalog runs in 2026-10. Its escalations caught
every big slip, but its overrides went against the reviewed catalog about
two to one, and a sample read half wrong. So an approving audit keeps the
curator's decisions, records what it would change, and `catalog-review`
lists the series until a person has looked.
"""

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog.audit_ops import (
    AuditFactUpdate,
    AuditOverride,
    AuditResult,
    apply_audit,
)
from lauschi_catalog.catalog.facts import EraBoundaryProposal
from lauschi_catalog.catalog.lifecycle import open_flags
from lauschi_catalog.commands.review_human import review_human
from tests.conftest import ScratchCatalog


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
def root(scratch_catalog: ScratchCatalog) -> ScratchCatalog:
    scratch_catalog.write_curation(_curation())
    return scratch_catalog


def _read(root: ScratchCatalog) -> dict:
    return root.read_curation("s")


def test_an_approving_audit_flags_an_override_and_changes_no_album(
    root: ScratchCatalog,
) -> None:
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


def test_an_override_that_flips_nothing_is_no_flag(root: ScratchCatalog) -> None:
    """Naming another reason for an excluded album changes what nobody sees."""
    result = AuditResult(approve=True, overrides=[_override("a2", "exclude")])
    assert apply_audit("s", result, model_name="critic") == "approved"
    assert open_flags(_read(root)) == []


def test_apply_overrides_keeps_the_auditor_deciding(root: ScratchCatalog) -> None:
    result = AuditResult(approve=True, overrides=[_override("a1", "exclude")])
    action = apply_audit("s", result, model_name="critic", apply_overrides=True)
    data = _read(root)
    assert action == "overridden"
    assert data["albums"][0]["include"] is False
    assert data["albums"][0]["decided_by"] == "critic"
    assert open_flags(data) == []


def test_too_many_flags_still_escalate(root: ScratchCatalog) -> None:
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
    root.write_curation(data)
    overrides = [_override(f"a{i}", "exclude") for i in range(1, 8)]
    result = AuditResult(approve=True, overrides=overrides)
    assert apply_audit("s", result, model_name="critic") == "escalated"


def test_a_decision_by_hand_settles_a_flag(root: ScratchCatalog) -> None:
    apply_audit(
        "s",
        AuditResult(approve=True, overrides=[_override("a1", "exclude")]),
        model_name="critic",
    )
    data = _read(root)
    data["albums"][0].update(decided_by="operator", decided_at="2999-01-01T00:00:00")
    assert open_flags(data) == []


def test_only_the_latest_audit_raises_flags(root: ScratchCatalog) -> None:
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


def test_review_lists_a_flagged_series_with_its_flags(root: ScratchCatalog) -> None:
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


# ── series facts: the same rule ─────────────────────────────────────────


def _with_facts(root: ScratchCatalog, facts: dict) -> None:
    data = _curation()
    data["series_facts"] = facts
    root.write_curation(data)


_ERA = {"label": "klassik", "release_date_range": "1996-2015", "curated_by": "curator"}


def test_restating_the_curators_fact_confirms_it(root: ScratchCatalog) -> None:
    _with_facts(root, {"era_boundaries": [dict(_ERA)]})
    update = AuditFactUpdate(
        era_boundaries=[
            EraBoundaryProposal(label="klassik", release_date_range="1996-2015")
        ]
    )
    action = apply_audit(
        "s", AuditResult(approve=True, fact_updates=[update]), model_name="critic"
    )
    era = _read(root)["series_facts"]["era_boundaries"][0]
    assert action == "overridden"
    assert era["audited_by"] == "critic"
    assert era["curated_by"] == "curator"


def test_a_fact_the_auditor_adds_is_a_flag(root: ScratchCatalog) -> None:
    """Gemma gave Bullerbü two eras of its own on 2026-10-14 and stamped
    them audited by itself."""
    _with_facts(root, {"era_boundaries": []})
    update = AuditFactUpdate(
        era_boundaries=[
            EraBoundaryProposal(label="klassiker", release_date_range="1949-1950")
        ]
    )
    action = apply_audit(
        "s", AuditResult(approve=True, fact_updates=[update]), model_name="critic"
    )
    data = _read(root)
    assert action == "flagged"
    assert data["series_facts"]["era_boundaries"] == []
    assert any(
        c.startswith("[fact_flag]") and "klassiker" in c
        for c in data["review"]["concerns"]
    )


def test_a_changed_fact_is_a_flag_and_stays_as_it_was(root: ScratchCatalog) -> None:
    _with_facts(root, {"era_boundaries": [dict(_ERA)]})
    update = AuditFactUpdate(
        era_boundaries=[
            EraBoundaryProposal(label="klassik", release_date_range="1996-2019")
        ]
    )
    apply_audit(
        "s", AuditResult(approve=True, fact_updates=[update]), model_name="critic"
    )
    data = _read(root)
    assert data["series_facts"]["era_boundaries"] == [_ERA]
    assert any(
        "[fact_flag]" in c and "1996-2019" in c for c in data["review"]["concerns"]
    )


def test_a_replace_that_drops_facts_is_a_flag(root: ScratchCatalog) -> None:
    """Gemma's replace wiped two audited eras and two known gaps of Hexe
    Lilli's Erstlesergeschichten on 2026-10-14."""
    gap = {"number": 7, "reason": "starts at 8", "curated_by": "curator"}
    _with_facts(root, {"era_boundaries": [dict(_ERA)], "known_gaps": [dict(gap)]})
    action = apply_audit(
        "s",
        AuditResult(approve=True, fact_updates=[AuditFactUpdate(mode="replace")]),
        model_name="critic",
    )
    data = _read(root)
    assert action == "flagged"
    assert data["series_facts"]["era_boundaries"] == [_ERA]
    assert data["series_facts"]["known_gaps"] == [gap]
    concerns = [c for c in data["review"]["concerns"] if c.startswith("[fact_flag]")]
    assert len(concerns) == 2


def test_apply_overrides_lets_the_auditor_write_facts(root: ScratchCatalog) -> None:
    _with_facts(root, {"era_boundaries": []})
    update = AuditFactUpdate(
        era_boundaries=[
            EraBoundaryProposal(label="klassiker", release_date_range="1949-1950")
        ]
    )
    apply_audit(
        "s",
        AuditResult(approve=True, fact_updates=[update]),
        model_name="critic",
        apply_overrides=True,
    )
    eras = _read(root)["series_facts"]["era_boundaries"]
    assert [e["label"] for e in eras] == ["klassiker"]


def test_review_lists_every_fact_flag(root: ScratchCatalog) -> None:
    _with_facts(root, {"era_boundaries": []})
    eras = [
        EraBoundaryProposal(label=f"era{i}", release_date_range=f"{1990 + i}-")
        for i in range(4)
    ]
    apply_audit(
        "s",
        AuditResult(approve=True, fact_updates=[AuditFactUpdate(era_boundaries=eras)]),
        model_name="critic",
    )
    out = CliRunner().invoke(review_human, ["-d", "-s", "approved"], terminal_width=200)
    assert out.exit_code == 0, out.output
    assert all(f"era{i}" in out.output for i in range(4))


def test_ignored_overrides_do_not_count_toward_the_volume_rule(
    root: ScratchCatalog,
) -> None:
    """Honigkuchenpferde escalated on 8 flips that were all on albums
    decided by hand, which the audit ignores anyway (2026-10-14)."""
    data = _curation()
    data["albums"] = [
        {
            "album_id": f"a{i}",
            "provider": "spotify",
            "include": False,
            "title": f"Lied {i} - Single",
            "exclude_reason": "music_single",
            "decided_by": "operator",
        }
        for i in range(1, 21)
    ]
    root.write_curation(data)
    overrides = [_override(f"a{i}", "include") for i in range(1, 9)]
    action = apply_audit(
        "s", AuditResult(approve=True, overrides=overrides), model_name="critic"
    )
    concerns = _read(root)["review"]["concerns"]
    assert action == "approved"
    assert not any("[override-volume]" in c for c in concerns)
    assert sum("[decided_by_hand]" in c for c in concerns) == 8
