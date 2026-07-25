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

from __future__ import annotations

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
    assert normalize_title("Die Wilden Hühner") == normalize_title(
        "die wilden huehner"
    )


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
