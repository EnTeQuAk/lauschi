"""A prior record excluded outside the curate agent is carried into a
re-curation under the nearest curate reason.

The audit pass, the deterministic duplicate settle and manual edits
record reasons the curate vocabulary does not know (audit_override,
same_provider_duplicate, ...). `curate --force` on Wieso? Weshalb?
Warum? aborted on 14 such records (2026-09-06) because the pre-seed
built an AlbumDecision from them verbatim. Each external reason names
the curate reason it is carried as; the notes keep the original text.
A reason nobody knows still aborts the run.
"""

import pytest

from lauschi_catalog.catalog import reasons
from lauschi_catalog.catalog.curate_ops import _preseed_decisions
from tests.factories import album_record, curation, discovered_album

DISCOVERED = [discovered_album("apple_music", "a", "Alles über Laster")]


@pytest.mark.parametrize(
    ("external", "carried"),
    [
        ("same_provider_duplicate", "duplicate"),
        ("audit_override", "unspecified"),
        ("incomplete_release", "partial_release"),
        ("wrong_artist", "different_series"),
        ("compilation_as_episode", "compilation"),
    ],
)
def test_an_external_reason_is_carried_as_its_curate_equivalent(external, carried):
    prior = curation(
        albums=[
            album_record(
                "a",
                provider="apple_music",
                include=False,
                exclude_reason=external,
                notes="Audit override applied: twin of apple_music:b",
            )
        ]
    )
    decisions, remaining = _preseed_decisions(DISCOVERED, prior)
    assert remaining == []
    assert decisions[0].include is False
    assert decisions[0].exclude_reason == carried
    assert decisions[0].notes == "Audit override applied: twin of apple_music:b"


def test_every_external_reason_names_what_it_is_carried_as():
    for reason in reasons.EXTERNAL_REASONS:
        assert reason.carried_as in reasons.CURATE_REASON_KEYS, reason.key


def test_an_unknown_reason_still_aborts():
    prior = curation(
        albums=[
            album_record(
                "a", provider="apple_music", include=False, exclude_reason="bogus"
            )
        ]
    )
    with pytest.raises(ValueError, match="invalid album records"):
        _preseed_decisions(DISCOVERED, prior)
