"""Normalizing exclude_reasons is idempotent and never invents values."""

import pytest

from lauschi_catalog.catalog.reconcile import (
    ALL_KNOWN_REASONS,
    normalize_exclude_reason,
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
