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


def _product(
    product_id: int,
    title: str,
    *,
    author: str = "Kommissar Kugelblitz",
    label: str = "EUROPA mini",
    line: tuple[str, str] | None = None,
    brand: str | None = None,
) -> dict:
    """A product as the search returns it. ``line`` is (line name, number)."""
    embedded: dict = {}
    if line is not None:
        embedded = {
            "series": [{"name": brand or "Kommissar Kugelblitz"}],
            "season": [{"name": line[0]}],
            "episodes": [{"episodeNumber": line[1], "episodeTitle": title}],
        }
    return {
        "id": product_id,
        "title": title,
        "author": author,
        "imprint": {"name": label},
        "productClassification": "RADIOPLAY",
        "attributes": {"length": 2880},
        "categories": [{"name": "Krimi"}],
        "_embedded": embedded,
    }


PRODUCT_PAGES = [
    {
        "_embedded": {
            "simpleHalRepresentationModels": [
                _product(1, "Die rote Socke", line=("Hörspiele zu den Büchern", "1")),
                _product(2, "Der grüne Schal"),
                _product(3, "Kugelblitz in London", author="Ursel Scheffler"),
            ]
        },
        "page": {"number": 0, "totalPages": 2},
    },
    {
        "_embedded": {
            "simpleHalRepresentationModels": [
                _product(4, "Blitz und Donner", author="Wetter für Kinder"),
                # filed under the brand, but the hit names no line
                _product(6, "Der blaue Hut", line=("", "7")),
                # an older, unfiled copy of a release that is filed
                _product(7, "Die Rote Socke!"),
                _product(
                    5,
                    "Folge 3: Kugelblitz und Co",
                    author="Krimi Kids",
                    line=("Hörspiele", "3"),
                    brand="Krimi Kids",
                ),
            ]
        },
        "page": {"number": 1, "totalPages": 2},
    },
]


def fake_fetch(url: str, params: dict | None) -> dict:
    if url.endswith("/series"):
        return PAGES[params["page"]]
    if url.endswith("/series/157"):
        return SERIES
    if url.endswith("/searches/products-by-clients"):
        assert params["query"] == "Kommissar Kugelblitz"
        return PRODUCT_PAGES[params["page"]]
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


def test_a_product_search_reads_every_page():
    products = index().products("Kommissar Kugelblitz")

    assert [p.title for p in products] == [
        "Die rote Socke",
        "Der grüne Schal",
        "Kugelblitz in London",
        "Blitz und Donner",
        "Der blaue Hut",
        "Die Rote Socke!",
        "Folge 3: Kugelblitz und Co",
    ]
    first, second = products[:2]
    assert (first.brand, first.line, first.number) == (
        "Kommissar Kugelblitz",
        "Hörspiele zu den Büchern",
        "1",
    )
    assert (first.label, first.kind, first.seconds) == (
        "EUROPA mini",
        "RADIOPLAY",
        2880,
    )
    assert (second.brand, second.line, second.number) == (None, None, None)


def test_a_brands_products_without_a_line():
    """The index holds products it files under no brand at all. The lines
    of a brand do not show them, so a title can look absent when it is
    not. The search is full text: only products that name the brand as
    their author or in their title count. A product filed under the brand
    is not one of them, even when the hit names no line, and neither is
    an unfiled copy of a release that is filed."""
    idx = index()
    series = idx.lines_for("Kommissar Kugelblitz")
    assert series is not None

    assert [p.title for p in idx.without_a_line(series)] == ["Der grüne Schal"]


def test_products_are_not_asked_for_without_configuration(monkeypatch):
    monkeypatch.delenv("REFERENCE_INDEX_URL", raising=False)

    def no_request(url, params):
        raise AssertionError("no request expected")

    assert ReferenceIndex(fetch=no_request).products("TKKG") == []
