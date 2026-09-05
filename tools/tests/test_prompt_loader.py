"""Tests for the prompt loader."""

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
        p = load_curate_skill(
            phase="finalize", content_type="hoerspiel", discography_span_years=15
        )
        assert "# Era detection" in p

    def test_skips_era_detection_when_span_short(self):
        p = load_curate_skill(
            phase="finalize", content_type="hoerspiel", discography_span_years=5
        )
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

    from lauschi_catalog.prompts import load_curate_skill

    prompt = load_curate_skill(phase="audit", content_type="hoerspiel")
    assert f"Today is {date.today().isoformat()}." in prompt


class TestAuditPhaseStandard:
    """The audit is a 4-eye check on content that reaches children.
    Chris's standard is that every album is examined and nothing is
    sampled; the earlier prompt told the model to sample HIGH-confidence
    decisions lightly, which is the opposite. Pin the standard so it
    cannot drift back."""

    def test_audit_examines_every_album_and_never_samples(self):
        p = load_curate_skill(phase="audit")
        assert "sample them lightly" not in p
        assert "nothing is sampled" in p
        assert "Look at every album" in p

    def test_audit_knows_a_chunk_is_partial_by_design(self):
        """A chunked audit tells the model its list is one chunk. The skill
        must frame that so the model judges the chunk against the whole
        rather than treating a partial list as the series."""
        p = load_curate_skill(phase="audit")
        assert "audited in chunks" in p
        assert "merge mode only" in p


class TestAlbumTypeStatement:
    """The compilation flag was called 'not always accurate' on a hunch.
    Measured 2026-09-05 it agrees with our decisions on 44 of 46 albums;
    the prompt must keep saying so until someone re-measures."""

    def test_hoerspiel_reference_calls_the_compilation_flag_a_strong_signal(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "It is a strong signal." in p
        assert "artist's own song collection" in p


class TestPolicyTeaching:
    """The policy decided 2026-09-05 is taught, not listed; these pins keep
    the statements that carry a decision alive until someone re-decides."""

    def test_two_stories_in_one_release_are_an_episode_and_doppelfolge_is_gone(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "Two stories in one release is not a repackaging" in p
        assert "Doppelfolge" not in p

    def test_eras_decide_duplicates_and_year_windows_are_gone(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "`era_boundary` fact places" in p
        assert "within ~2 years" not in p

    def test_a_future_release_date_is_never_a_reason_to_exclude(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "Release dates in the future" in p
        assert "not a reason to exclude" in p

    def test_sibling_entries_are_stated_not_guessed(self):
        p = load_curate_skill(phase="batch", content_type="hoerspiel")
        assert "the prompt lists the sibling entries" in p

    def test_split_guidelines_teach_erstleser_films_and_one_advent_child(self):
        p = load_curate_skill(phase="finalize", content_type="hoerspiel")
        assert "Erstleser" in p
        assert 'Three different products carry the word "Kinofilm"' in p
        assert "Both shapes go into the same single child" in p
        assert "Doppelfolgen und Sammelbände" not in p
