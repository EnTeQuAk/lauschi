"""A series without facts curates with empty facts, not with None.

The H2O Staffel 3 child (2026-09-06), freshly split with
`series_facts: {}` and no facts in series.yaml, crashed the curate
flow: merge_facts returns None when nothing survives, and the finalize
step read `.era_boundaries` off it.
"""

from lauschi_catalog.catalog.curate_ops import _carry_facts
from lauschi_catalog.catalog.facts import SeriesFacts


def test_no_facts_anywhere_yields_empty_facts():
    facts = _carry_facts(SeriesFacts(), {"series_facts": {}})
    assert isinstance(facts, SeriesFacts)
    assert facts.era_boundaries == [] and facts.known_gaps == []


def test_prior_curation_facts_are_carried():
    prior = {
        "series_facts": {
            "known_gaps": [
                {"number": 7, "reason": "never released", "curated_by": "curate"}
            ]
        }
    }
    facts = _carry_facts(SeriesFacts(), prior)
    assert [g.number for g in facts.known_gaps] == [7]
