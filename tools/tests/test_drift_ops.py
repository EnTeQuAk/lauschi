"""Tests for catalog/drift_ops.py.

Fixtures come from real drift we hit in July 2026, so the classifier is
pinned against cases that actually shipped rather than invented ones:

- Bibi Blocksberg: four Apple Music records pointed at the wrong albums
  (a kid tapping "Folge 59" heard Folge 61). Must be CRITICAL.
- TiRiLi / Laura / Petronella: album IDs removed and re-released under
  new ones. Must be GONE.
- Apple Music appending " - Single" and adding a comma to
  "Kinderklassiker Vol. 1". Must be INFO, never CRITICAL.
- Volker Rosin's "(Remastered 2024)": a genuinely different edition we
  deliberately exclude. Normalization must not collapse it into the
  original.
"""

import json as _json
import os
from datetime import date

from lauschi_catalog.catalog.drift_ops import (
    DriftSeverity,
    classify_album_drift,
    normalize_title,
    title_similarity,
)

FOLGE = r"^Folge (\d+):"


# ── normalization ─────────────────────────────────────────────────────────


def test_normalize_folds_case_punctuation_and_umlauts():
    assert normalize_title("Kinderklassiker, Vol. 1") == normalize_title(
        "Kinderklassiker Vol. 1"
    )
    assert normalize_title("Die Wilden Hühner") == normalize_title("die wilden huehner")


def test_normalize_strips_store_format_suffixes():
    assert normalize_title("Frauen-WM-Wissen 01 - EP") == normalize_title(
        "Frauen-WM-Wissen 01"
    )
    assert normalize_title("Alle meine Entchen - Single") == normalize_title(
        "Alle meine Entchen"
    )


def test_normalize_keeps_parentheticals():
    """'(Remastered 2024)' marks a different edition we exclude on
    purpose. Collapsing it into the original would hide real drift."""
    assert normalize_title("Beatles für Kinder (Remastered 2024)") != (
        normalize_title("The Beatles für Kinder")
    )


def test_similarity_is_one_for_equal_and_low_for_unrelated():
    assert title_similarity("Folge 59: und Dino", "Folge 59: und Dino") == 1.0
    assert title_similarity("Folge 59: und Dino", "Die kleine Hexe") < 0.5


# ── identity drift: the Bibi Blocksberg class ─────────────────────────────


def test_episode_number_disagreement_is_critical():
    finding = classify_album_drift(
        album_id="1143597516",
        provider="apple_music",
        stored_title="Folge 59: und Dino",
        stored_episode=59,
        stored_release="1994",
        live_title="Folge 61: Der Flaschengeist",
        live_release="1994",
        pattern=FOLGE,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.critical
    assert "61" in finding.detail and "59" in finding.detail


def test_matching_episode_number_with_retitled_subtitle_is_warning():
    """Same episode, publisher touched the subtitle: worth surfacing,
    not worth alarming."""
    finding = classify_album_drift(
        album_id="a1",
        provider="spotify",
        stored_title="Folge 12: Der Superstar",
        stored_episode=12,
        stored_release="2011",
        live_title="Folge 12: Benjamin als Superstar",
        live_release="2011",
        pattern=FOLGE,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.warning


def test_identical_title_produces_no_finding():
    assert (
        classify_album_drift(
            album_id="a1",
            provider="spotify",
            stored_title="Folge 12: Der Superstar",
            stored_episode=12,
            stored_release="2011",
            live_title="Folge 12: Der Superstar",
            live_release="2011",
            pattern=FOLGE,
        )
        is None
    )


# ── cosmetic drift must never be critical ────────────────────────────────


def test_added_comma_is_info():
    finding = classify_album_drift(
        album_id="6777229583",
        provider="apple_music",
        stored_title="Kinderklassiker Vol. 1",
        stored_episode=None,
        stored_release="2024-11-29",
        live_title="Kinderklassiker, Vol. 1",
        live_release="2024-11-29",
        pattern=None,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.info


def test_appended_single_suffix_is_info():
    finding = classify_album_drift(
        album_id="6776369727",
        provider="apple_music",
        stored_title="Alle meine Entchen",
        stored_episode=None,
        stored_release="2024",
        live_title="Alle meine Entchen - Single",
        live_release="2024",
        pattern=None,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.info


# ── pattern-less content falls back to similarity ─────────────────────────


def test_unrelated_title_without_pattern_is_critical():
    finding = classify_album_drift(
        album_id="a1",
        provider="apple_music",
        stored_title="Coco (Hörspiel zum Disney/Pixar Film)",
        stored_episode=None,
        stored_release="2017",
        live_title="Quanto ci costa essere noi - EP",
        live_release="2016",
        pattern=None,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.critical


def test_release_year_change_alone_is_warning():
    finding = classify_album_drift(
        album_id="a1",
        provider="spotify",
        stored_title="Die Wilden Hühner",
        stored_episode=None,
        stored_release="1998",
        live_title="Die Wilden Hühner",
        live_release="2022",
        pattern=None,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.warning


def test_missing_live_release_does_not_trigger_year_drift():
    """Providers sometimes drop the release date; absence is not drift."""
    assert (
        classify_album_drift(
            album_id="a1",
            provider="spotify",
            stored_title="Die Wilden Hühner",
            stored_episode=None,
            stored_release="1998",
            live_title="Die Wilden Hühner",
            live_release="",
            pattern=None,
        )
        is None
    )


# ── gone ──────────────────────────────────────────────────────────────────


def test_absent_album_is_gone():
    finding = classify_album_drift(
        album_id="1779681614",
        provider="apple_music",
        stored_title="Kinderklassiker Vol. 1",
        stored_episode=None,
        stored_release="2024-11-29",
        live_title=None,
        live_release=None,
        pattern=None,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.gone
    assert finding.live_title is None


# ── the same-episode rescue needs a floor ─────────────────────────────────
#
# Calibrated against the 2026-07-25 full sweep. Legitimate publisher
# renames that share an episode number sit at 0.57-0.99 similarity
# (suffix appends like "(Das Original-Hörspiel zur TV-Serie)", a typo
# fix). One pair sat at 0.22 with unrelated titles and only a
# coincidentally matching episode number, and the rescue wrongly kept it
# out of the loud channel.


def test_matching_episode_does_not_rescue_unrelated_titles():
    """prinzessin_lillifee: 'Vorhang auf für Prinzessin Lillifee' against
    '06/Das Hörspiel zur TV-Serie'. Both yield episode 6, but a shared
    number is weak evidence when nothing else matches."""
    finding = classify_album_drift(
        album_id="3ZYrlaczw1qMYuXnmL43k5",
        provider="spotify",
        stored_title="Vorhang auf für Prinzessin Lillifee",
        stored_episode=6,
        stored_release="2010",
        live_title="06/Das Hörspiel zur TV-Serie",
        live_release="2010",
        pattern=r"^(\d+)/",
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.critical


def test_matching_episode_still_rescues_a_long_suffix_append():
    """die_playmos at 0.61: same episode, publisher appended a long
    qualifier. Must stay a warning."""
    finding = classify_album_drift(
        album_id="0DeLb048gWpWg15yEbMvC0",
        provider="spotify",
        stored_title="Folge 100: Der magische Ring",
        stored_episode=100,
        stored_release="2019",
        live_title="Folge 100: Der magische Ring (Das Original Playmobil Hörspiel)",
        live_release="2019",
        pattern=FOLGE,
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.warning


def test_matching_episode_rescues_a_typo_fix():
    """sternenfohlen at 0.99."""
    finding = classify_album_drift(
        album_id="2Tas15aBGmhh355uvDh4OD",
        provider="spotify",
        stored_title="Teil 42: Das fantastische Zaubertunier",
        stored_episode=42,
        stored_release="2021",
        live_title="Teil 42: Das fantastische Zauberturnier",
        live_release="2021",
        pattern=r"^Teil (\d+):",
    )
    assert finding is not None
    assert finding.severity is DriftSeverity.warning


# ── a corrupt curation must not read as "no drift" ────────────────────────


def test_corrupt_curation_raises_instead_of_reporting_no_drift(tmp_path):
    """A verification tool that hides its own blind spots is worse than
    none: silently skipping an unreadable series would report it as clean."""
    import pytest

    from lauschi_catalog.catalog import drift_ops

    bad = tmp_path / "assets" / "catalog" / "curation" / "broken_series.json"
    bad.parent.mkdir(parents=True)
    bad.write_text("{not valid json")
    os.environ["LAUSCHI_REPO_ROOT"] = str(tmp_path)
    try:
        with pytest.raises(_json.JSONDecodeError):
            drift_ops.stored_album_records("broken_series", "spotify")
    finally:
        del os.environ["LAUSCHI_REPO_ROOT"]


def test_missing_curation_is_not_an_error(tmp_path):
    """Absent is different from corrupt: a series with no curation file is
    reported via unresolved_series, not a crash."""
    from lauschi_catalog.catalog import drift_ops

    os.environ["LAUSCHI_REPO_ROOT"] = str(tmp_path)
    try:
        assert drift_ops.stored_album_records("nope", "spotify") == []
    finally:
        del os.environ["LAUSCHI_REPO_ROOT"]


def test_unresolved_id_with_a_future_release_date_is_pending_not_gone():
    """A pre-release ships in the catalog and is hidden by the app until
    its date; the provider may not resolve the id before then. That is
    expected, not a loss."""
    finding = classify_album_drift(
        album_id="x",
        provider="apple_music",
        stored_title="Folge 166: Das verhexte Labyrinth",
        stored_episode=166,
        stored_release="2026-10-09",
        live_title=None,
        live_release=None,
        pattern=r"^Folge (\d+):",
        today=date(2026, 9, 5),
    )
    assert finding is not None
    assert finding.severity == DriftSeverity.pending
    assert "2026-10-09" in finding.detail


def test_unresolved_id_with_a_past_release_date_is_gone():
    finding = classify_album_drift(
        album_id="x",
        provider="spotify",
        stored_title="Folge 1: Alt",
        stored_episode=1,
        stored_release="2020-01-01",
        live_title=None,
        live_release=None,
        pattern=r"^Folge (\d+):",
        today=date(2026, 9, 5),
    )
    assert finding is not None and finding.severity == DriftSeverity.gone


def test_unresolved_id_without_a_usable_date_is_gone():
    for stored in (None, "", "2030"):
        finding = classify_album_drift(
            album_id="x",
            provider="spotify",
            stored_title="Folge 1: Alt",
            stored_episode=1,
            stored_release=stored,
            live_title=None,
            live_release=None,
            pattern=None,
            today=date(2026, 9, 5),
        )
        assert finding is not None and finding.severity == DriftSeverity.gone, stored
