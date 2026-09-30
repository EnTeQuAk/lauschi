"""The existing facts as finalize is shown them."""

from lauschi_catalog.catalog.curate_ops import existing_facts_lines
from lauschi_catalog.catalog.facts import SeriesFacts


def test_empty_facts_say_so() -> None:
    assert existing_facts_lines(SeriesFacts()) == ["Existing facts: (none)"]


def test_each_kind_of_fact_is_listed_under_its_heading() -> None:
    facts = SeriesFacts.model_validate(
        {
            "era_boundaries": [
                {"label": "Neuauflage", "release_date_range": "2019-2026"}
            ],
            "known_gaps": [
                {"number": 40, "reason": "never released"},
                {"number": 7, "range_end": 9, "reason": "withdrawn"},
            ],
            "sub_series": [{"label": "JUNIOR", "reason": "own numbering"}],
        }
    )
    assert existing_facts_lines(facts) == [
        "Existing era_boundaries:",
        "  - Neuauflage: 2019-2026",
        "Existing known_gaps:",
        "  - Episode 40: never released",
        "  - Episode 7-9: withdrawn",
        "Existing sub_series:",
        "  - JUNIOR: own numbering",
    ]
