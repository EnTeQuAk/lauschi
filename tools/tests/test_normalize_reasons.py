"""Normalizing exclude_reasons is idempotent and never invents values."""

import pytest

from lauschi_catalog.catalog.reconcile import (
    ALL_KNOWN_REASONS,
    label_from_title,
    normalize_exclude_reason,
    normalized_reason,
)

VALID = ALL_KNOWN_REASONS


@pytest.mark.parametrize(
    "reason",
    [None, "", "compilation", "audit_override", "same_provider_duplicate"],
)
def test_known_values_pass_through_unchanged(reason):
    assert normalize_exclude_reason(reason) == reason


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (
            "sub_series_bleed: lives in jan_tenner_der_neue_superheld",
            "sub_series_bleed",
        ),
        ("Wrong content type: Audiobook", "wrong_content_type"),
        ("Wrong content type: it is an audiobook", "wrong_content_type"),
        ("Duplicate episode 25", "duplicate"),
        ("music single", "music_single"),
        ("sub_series", "sub_series_bleed"),
        ("totally unparseable free text", "unspecified"),
    ],
)
def test_verbose_values_map_to_the_enum(raw, expected):
    assert normalize_exclude_reason(raw) == expected


def test_normalization_is_idempotent():
    """A second pass over an already-normalized value returns it
    unchanged, so the migration can be re-run safely."""
    for raw in [
        "sub_series_bleed: lives in kalle_klang",
        "Wrong content type: Audiobook chapter",
        "duplicate",
        "unknown noise",
        None,
        "",
    ]:
        once = normalize_exclude_reason(raw)
        assert normalize_exclude_reason(once) == once, raw


def test_ever_output_is_a_valid_enum_value_or_none_or_empty():
    for raw in [
        "sub_series_bleed: lives in X",
        "nonsense",
        "wrong content type",
        "",
        None,
        "audit_override",
    ]:
        out = normalize_exclude_reason(raw)
        assert out is None or out == "" or out in VALID, raw


@pytest.mark.parametrize(
    ("title", "expected"),
    [
        ("Ahoi, Piraten! (Das Piraten-Lied) - Single", "music_single"),
        ("Die Affen rasen durch den Wald - single", "music_single"),
        ("Aqua Party (Instrumentals)", "format_variant"),
        ("BOAH ist das krass (Instrumental)", "format_variant"),
        ("Rolfs Lieder (Karaoke Version)", "format_variant"),
        ("Folge 12: Der Fluch", None),
        ("Sing mit mir Vol. 1 - EP", None),
    ],
)
def test_the_providers_own_title_suffix_names_the_reason(title, expected):
    assert label_from_title(title) == expected


def test_a_blank_or_unspecified_reason_is_filled_from_the_title():
    album = {
        "include": False,
        "exclude_reason": "unspecified",
        "title": "Herbst - Single",
    }
    assert normalized_reason(album) == "music_single"
    album = {"include": False, "exclude_reason": None, "title": "Party (Instrumental)"}
    assert normalized_reason(album) == "format_variant"


def test_a_named_reason_is_never_overwritten_by_the_title():
    album = {
        "include": False,
        "exclude_reason": "compilation",
        "title": "Hits - Single",
    }
    assert normalized_reason(album) == "compilation"


def test_a_title_without_a_marker_leaves_unspecified_alone():
    album = {
        "include": False,
        "exclude_reason": "unspecified",
        "title": "5 kleine Fische",
    }
    assert normalized_reason(album) == "unspecified"
