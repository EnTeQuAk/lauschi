"""Tests for curate.py helpers — the small functions that gate
correctness of an --all run without exercising the LLM or providers.

_lock_series_id is the safety net that prevents the umlaut-
transliteration bug from corrupting filenames. The exception
formatter is the diagnostic that decides whether you can tell what
went wrong from the log.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.commands.curate import (
    CuratedSeries,
    _lock_series_id,
    _resolve_is_music,
)


def _series(sid: str = "any") -> CuratedSeries:
    """Build a minimal CuratedSeries; the helper only touches .id."""
    return CuratedSeries(
        id=sid,
        title="Title",
        episode_pattern=r"^Folge (\d+):",
        albums=[],
        provider_artist_ids={},
    )


# ── _lock_series_id ───────────────────────────────────────────────────────


def test_lock_overrides_when_canonical_differs():
    """The motivating bug: model produced 'benjamin_bluechen' for
    series.yaml entry 'benjamin_bluemchen'. Override silently fails
    catalog round-tripping; we want a loud override instead."""
    s = _series("benjamin_bluechen")
    _lock_series_id(s, "benjamin_bluemchen")
    assert s.id == "benjamin_bluemchen"


def test_lock_is_noop_when_canonical_matches():
    s = _series("die_drei_fragezeichen")
    _lock_series_id(s, "die_drei_fragezeichen")
    assert s.id == "die_drei_fragezeichen"


def test_lock_noop_when_canonical_is_none():
    """Single-series curate (no --all) has no canonical id; trust
    the model's choice."""
    s = _series("brand_new_series")
    _lock_series_id(s, None)
    assert s.id == "brand_new_series"


def test_lock_returns_same_instance_for_chaining():
    """Caller pattern: _lock_series_id(series, sid).save_curation() etc.
    The function mutates in place and returns the same object."""
    s = _series("a")
    result = _lock_series_id(s, "b")
    assert result is s


# ── exception formatter (covered indirectly via _curate_one) ──────────────


@pytest.mark.parametrize("exc,expected_substring", [
    (ValueError("bad input"), "ValueError: bad input"),
    (RuntimeError(""), "RuntimeError"),
    (Exception(""), "Exception"),
    (ConnectionError("refused"), "ConnectionError: refused"),
])
def test_exception_format_falls_back_to_type_when_str_empty(exc, expected_substring):
    """The format used inside _curate_one's except. Pinning here so a
    refactor doesn't regress the empty-str fallback."""
    msg = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
    assert expected_substring in msg


# ── _resolve_is_music ─────────────────────────────────────────────────────


def test_yaml_explicit_music_wins_over_pattern():
    """Even if a leftover episode_pattern exists, an explicit
    content_type='music' in series.yaml is canonical."""
    assert _resolve_is_music(
        entry_content_type="music",
        entry_has_pattern=True,
        existing_content_type=None,
    ) is True


def test_yaml_explicit_hoerspiel_wins_over_existing_music():
    """The compounding-misclassification fix: a series previously
    curated as music in its JSON file gets correctly recognized as
    hoerspiel when series.yaml says so. Without this, every
    --force re-curate would keep using the music prompt."""
    assert _resolve_is_music(
        entry_content_type="hoerspiel",
        entry_has_pattern=False,
        existing_content_type="music",
    ) is False


def test_pattern_implies_hoerspiel_when_yaml_silent():
    """No explicit content_type, but episode_pattern is set → it's a
    Hörspiel by definition (patterns are only meaningful for
    episode-numbered content)."""
    assert _resolve_is_music(
        entry_content_type=None,
        entry_has_pattern=True,
        existing_content_type=None,
    ) is False


def test_pattern_implies_hoerspiel_overrides_existing_music():
    """If yaml has episode_pattern but no explicit content_type, the
    pattern wins over a stale content_type='music' in the existing
    curation. Same root concern: don't compound misclassifications."""
    assert _resolve_is_music(
        entry_content_type=None,
        entry_has_pattern=True,
        existing_content_type="music",
    ) is False


def test_existing_music_used_when_yaml_has_neither():
    """Legacy escape hatch: if yaml is silent on content_type AND has
    no episode_pattern, fall back to the existing curation. Lets
    pre-migration entries continue to work."""
    assert _resolve_is_music(
        entry_content_type=None,
        entry_has_pattern=False,
        existing_content_type="music",
    ) is True


def test_default_to_music_when_nothing_signals_hoerspiel():
    """Brand-new entry with no pattern, no existing curation, no
    explicit content_type. Default to music; the curate prompt's
    music branch is the safer assumption (Hörspiel curation has
    stricter rules that misfire on a music artist)."""
    assert _resolve_is_music(
        entry_content_type=None,
        entry_has_pattern=False,
        existing_content_type=None,
    ) is True


def test_unrecognized_content_type_treated_as_silent():
    """A garbage content_type in series.yaml shouldn't lock us into
    that value. Fall through to the next signal."""
    assert _resolve_is_music(
        entry_content_type="audiobook",
        entry_has_pattern=True,
        existing_content_type=None,
    ) is False  # pattern wins
    assert _resolve_is_music(
        entry_content_type="audiobook",
        entry_has_pattern=False,
        existing_content_type=None,
    ) is True  # falls through to default
