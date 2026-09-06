"""The public line index client, offline: matching, parsing, paging,
and the unconfigured case."""

import pytest

from lauschi_catalog.reference import ReferenceIndex, _key

PAGES = [
    {
        "_embedded": {
            "series": [
                {"id": 157, "name": "Kommissar Kugelblitz "},
                {"id": 108, "name": "Bibi Blocksberg"},
            ]
        },
        "page": {"number": 0, "totalPages": 2},
    },
    {
        "_embedded": {
            "series": [{"id": 92, "name": "TKKG Junior"}, {"id": 5, "name": "TKKG"}]
        },
        "page": {"number": 1, "totalPages": 2},
    },
]
SERIES = {
    "id": 157,
    "name": "Kommissar Kugelblitz ",
    "seasons": [
        {
            "name": "Hörspiele zu den Büchern",
            "episodes": [
                {
                    "episodeNumber": "1",
                    "episodeTitle": "Die rote Socke ",
                    "length": "3674",
                },
                {"episodeNumber": None, "episodeTitle": "Sammelband", "length": None},
            ],
        },
        {"name": "Musik", "episodes": []},
    ],
}


def fake_fetch(url: str, params: dict | None) -> dict:
    if url.endswith("/series"):
        return PAGES[params["page"]]
    if url.endswith("/series/157"):
        return SERIES
    raise AssertionError(url)


def index() -> ReferenceIndex:
    return ReferenceIndex(
        "https://example.test/api/", fetch=fake_fetch, use_cache=False
    )


def test_unconfigured_index_answers_without_a_request(monkeypatch):
    monkeypatch.delenv("REFERENCE_INDEX_URL", raising=False)

    def no_request(url, params):
        raise AssertionError("no request expected")

    idx = ReferenceIndex(fetch=no_request)
    assert idx.configured is False
    assert idx.find("TKKG") == []
    assert idx.lines_for("TKKG") is None


def test_names_come_from_every_page():
    assert index().names() == {
        157: "Kommissar Kugelblitz",
        108: "Bibi Blocksberg",
        92: "TKKG Junior",
        5: "TKKG",
    }


def test_exact_name_matches_come_before_partial_ones():
    assert index().find("tkkg") == [(5, "TKKG"), (92, "TKKG Junior")]
    assert index().find("Kommissar Kugelblitz")[0] == (157, "Kommissar Kugelblitz")
    assert index().find("Conni") == []


def test_a_series_parses_into_lines_and_episodes():
    series = index().lines_for("Kommissar Kugelblitz")
    assert series is not None
    assert series.name == "Kommissar Kugelblitz"
    assert [line.name for line in series.lines] == ["Hörspiele zu den Büchern", "Musik"]
    first, second = series.lines[0].episodes
    assert (first.number, first.title, first.seconds) == ("1", "Die rote Socke", 3674)
    assert (second.number, second.seconds) == (None, None)


@pytest.mark.parametrize(
    ("name", "key"),
    [
        ("Die drei ??? Kids", "die drei kids"),
        ("Kommissar Kugelblitz ", "kommissar kugelblitz"),
        ("H2O – Plötzlich Meerjungfrau", "h2o plötzlich meerjungfrau"),
    ],
)
def test_matching_key_folds_case_punctuation_and_spacing(name, key):
    assert _key(name) == key
