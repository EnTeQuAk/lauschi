"""The rendered vocabularies must match the pre-refactor frozensets exactly.

Each rendered set is compared against a literal copy of the set it
replaced, so a vocabulary change fails loudly here before it silently
changes lint or reconcile behavior. Update the literal sets and the
tests together when the vocabulary intentionally changes.
"""

from typing import get_args

from lauschi_catalog.catalog import reasons
from lauschi_catalog.catalog.curate_ops import ExcludeReason
from lauschi_catalog.catalog.lint_ops import _CONTENT_REASONS
from lauschi_catalog.catalog.reconcile import (
    _AUTO_FLIP_REASONS,
    _FLAG_REASONS,
    ALL_KNOWN_REASONS,
    EXCLUDE_REASONS,
)


def test_curate_reason_keys_match_the_existing_literal() -> None:
    assert tuple(reasons.CURATE_REASON_KEYS) == get_args(ExcludeReason)


def test_contradiction_reasons_match_the_existing_lint_set() -> None:
    assert reasons.CONTRADICTION_REASON_KEYS == _CONTENT_REASONS


def test_auto_flip_reasons_match_the_existing_reconcile_set() -> None:
    assert reasons.AUTO_FLIP_REASON_KEYS == _AUTO_FLIP_REASONS


def test_flag_reasons_match_the_existing_reconcile_set() -> None:
    assert reasons.FLAG_REASON_KEYS == _FLAG_REASONS


def test_all_reason_keys_match_the_existing_reconcile_union() -> None:
    assert reasons.ALL_REASON_KEYS == ALL_KNOWN_REASONS
    assert set(reasons.CURATE_REASON_KEYS) == EXCLUDE_REASONS


def test_prompt_table_matches_the_curate_reasons() -> None:
    table_keys = [k for k, _ in reasons.CURATE_REASON_TABLE]
    assert table_keys == list(get_args(ExcludeReason))


def test_every_reason_has_a_description() -> None:
    for r in reasons.CURATE_REASONS + reasons.EXTERNAL_REASONS:
        assert r.description, r.key


def test_get_reason_resolves_every_declared_key() -> None:
    for key in reasons.ALL_REASON_KEYS:
        assert reasons.get_reason(key).key == key
