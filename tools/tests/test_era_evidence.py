"""Finalize is only asked about era collisions it is actually shown.

Ferien auf Saltkrokan's finalize was told "the batch phase flagged the
following albums as era collisions" with no album under it: the notes
matched the substring "era" (several, literary) and the albums carried
no episode number, so nothing was listed. It spent 24 requests looking
for the missing list (2026-10-01).
"""

from lauschi_catalog.catalog.curate_ops import era_evidence_lines
from tests.factories import decision


def test_unnumbered_era_notes_make_no_section() -> None:
    d = decision("s1", include=True, notes="Era collision with the 1964 release")
    assert era_evidence_lines([d]) == []


def test_era_inside_another_word_is_not_evidence() -> None:
    d = decision(
        "p1", include=True, episode_num=3, notes="One of several literary adaptations"
    )
    assert era_evidence_lines([d]) == []


def test_a_numbered_era_collision_is_listed() -> None:
    d = decision(
        "w1",
        include=True,
        episode_num=40,
        title="Folge 40",
        release_date="2019-01-01",
        notes="Era collision: same number as the 2007 story",
    )
    lines = era_evidence_lines([d])
    assert any("era collisions" in line for line in lines)
    assert "    ep 40 | 2019-01-01 | Folge 40" in lines
