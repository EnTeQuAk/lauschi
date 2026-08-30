"""Twelve committed curations carry `"review": null`. Every reader that
did `curation.get("review", {})` got None back for a present-but-null
key, so a full `audit` run and `catalog-apply` crashed on the first
such file (reproduced 2026-08-31 on das_sams_hoerbuch)."""

from __future__ import annotations

import pytest

from lauschi_catalog.catalog import apply_ops, lifecycle
from lauschi_catalog.catalog.lifecycle import audit_is_stale, review_block


@pytest.mark.parametrize(
    "curation, expected",
    [
        ({"review": None}, {}),
        ({}, {}),
        ({"review": {"status": "approved"}}, {"status": "approved"}),
    ],
)
def test_review_block_is_a_dict_whatever_the_file_holds(
    curation: dict, expected: dict
) -> None:
    assert review_block(curation) == expected


def test_a_null_review_is_not_stale_and_does_not_crash() -> None:
    assert (
        audit_is_stale({"review": None, "curated_at": "2026-08-01T00:00:00+00:00"})
        is False
    )


def test_apply_refuses_a_null_review_curation_instead_of_crashing() -> None:
    reason = apply_ops.should_apply(
        {
            "id": "das_sams_hoerbuch",
            "review": None,
            "albums": [],
            "curated_at": "2026-08-01T00:00:00+00:00",
        },
        force=False,
    )
    assert reason is not None and "status is 'curated'" in reason


def test_lifecycle_module_owns_the_helper() -> None:
    # every reader goes through the one definition
    assert lifecycle.review_block is review_block
