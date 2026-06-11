"""Tests for the prompt loader."""

from __future__ import annotations

import pytest

from lauschi_catalog.prompts import load_curate_skill


class TestLoadCurateSkill:
    """Snapshot-style assertions on assembled prompt content."""

    def test_loads_skill_header(self):
        p = load_curate_skill(phase="metadata")
        assert "# Lauschi Catalog Curation Skill" in p

    def test_loads_phase_suffix(self):
        p = load_curate_skill(phase="metadata")
        assert "## Phase: Metadata extraction" in p

        p = load_curate_skill(phase="batch")
        assert "## Phase: Batch curation" in p

        p = load_curate_skill(phase="finalize")
        assert "## Phase: Finalize" in p

    def test_loads_content_type_reference(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "cross_provider_pair" in p

        p = load_curate_skill(phase="batch", content_type="music")
        assert "kinderlieder_compilation" in p

        p = load_curate_skill(phase="batch", content_type="audiobook")
        assert "ungekuerzt_reading" in p

    def test_loads_era_detection_when_span_long(self):
        p = load_curate_skill(phase="finalize", content_type="hoerspiel", discography_span_years=15)
        assert "# Era detection" in p

    def test_skips_era_detection_when_span_short(self):
        p = load_curate_skill(phase="finalize", content_type="hoerspiel", discography_span_years=5)
        assert "# Era detection" not in p

    def test_composition_order(self):
        """SKILL.md comes before phase suffix."""
        p = load_curate_skill(phase="metadata")
        skill_pos = p.index("# Lauschi Catalog Curation Skill")
        phase_pos = p.index("## Phase: Metadata extraction")
        assert skill_pos < phase_pos

    def test_unknown_phase_raises(self):
        with pytest.raises(FileNotFoundError):
            load_curate_skill(phase="invalid")  # type: ignore[arg-type]

    def test_cross_provider_worked_example_present(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "01/Majas Geburt" in p
        assert "Klassiker, Folge 1" in p


def test_curate_skill_contains_current_date():
    """Models date-reason from their training cutoff (an auditor once
    flagged a three-month-old release as 'future'). Every assembled
    prompt carries today's date so release-date reasoning has an
    anchor."""
    from datetime import date
    from lauschi_catalog.prompts import load_curate_skill

    prompt = load_curate_skill(phase="batch", content_type="hoerspiel")
    assert f"Today is {date.today().isoformat()}." in prompt


def test_audit_system_prompt_contains_current_date():
    from datetime import date
    from lauschi_catalog.catalog.audit_ops import audit_system_prompt

    assert f"Today is {date.today().isoformat()}." in audit_system_prompt()
