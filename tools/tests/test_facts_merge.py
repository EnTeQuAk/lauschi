"""Pin facts carry-forward across re-curations.

Re-curation only loaded existing_facts from series.yaml; the facts in
the prior curation JSON were silently discarded, so every re-curation
threw away discovered era_boundaries/known_gaps/sub_series unless they
had already been applied to series.yaml. merge_facts +
facts_from_curation carry them forward, deduped by natural key (era
label, gap number, sub_series label), first source wins.
"""

from __future__ import annotations

from lauschi_catalog.catalog.facts import (
    EraBoundary,
    KnownGap,
    SeriesFacts,
    SubSeriesFact,
    facts_from_curation,
    merge_facts,
)


def _facts(eras=(), gaps=(), subs=()):
    return SeriesFacts(
        era_boundaries=[
            EraBoundary(label=lbl, release_date_range=r) for lbl, r in eras
        ],
        known_gaps=[KnownGap(number=n, reason="r") for n in gaps],
        sub_series=[SubSeriesFact(label=lbl) for lbl in subs],
    )


def test_merge_dedupes_by_natural_key_first_wins():
    frozen = _facts(eras=[("klassik", "1976-1979")], gaps=[19])
    prior = _facts(
        eras=[("klassik", "1976-1980"), ("cgi", "2015-")],
        gaps=[19, 23],
        subs=["kinofilm"],
    )
    merged = merge_facts(frozen, prior)
    assert [e.label for e in merged.era_boundaries] == ["klassik", "cgi"]
    # first source wins on conflict
    assert merged.era_boundaries[0].release_date_range == "1976-1979"
    assert [g.number for g in merged.known_gaps] == [19, 23]
    assert [s.label for s in merged.sub_series] == ["kinofilm"]


def test_merge_skips_none_sources():
    prior = _facts(gaps=[7])
    merged = merge_facts(None, prior, None)
    assert [g.number for g in merged.known_gaps] == [7]


def test_merge_all_none_or_empty_returns_none():
    assert merge_facts(None, None) is None
    assert merge_facts(SeriesFacts(), None) is None


def test_facts_from_curation_reads_series_facts():
    curation = {"series_facts": {"known_gaps": [{"number": 19, "reason": "legal"}]}}
    facts = facts_from_curation(curation)
    assert [g.number for g in facts.known_gaps] == [19]


def test_facts_from_curation_tolerates_missing_and_malformed():
    assert facts_from_curation(None) is None
    assert facts_from_curation({}) is None
    assert facts_from_curation({"series_facts": {"known_gaps": [{"bogus": 1}]}}) is None
