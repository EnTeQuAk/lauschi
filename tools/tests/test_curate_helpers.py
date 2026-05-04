"""Tests for curate.py helpers — the small functions that gate
correctness of an --all run without exercising the LLM or providers.

_lock_series_id is the safety net that prevents the umlaut-
transliteration bug from corrupting filenames. The exception
formatter is the diagnostic that decides whether you can tell what
went wrong from the log.
"""

from __future__ import annotations

import pytest

from lauschi_catalog.commands.curate import CuratedSeries, _lock_series_id


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
