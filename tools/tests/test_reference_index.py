"""The public reference index, offline: matching, caching, the products
without a line, and the unconfigured case. The source here is a fake, the
real one reads the index outside this repo."""

from pathlib import Path

import pytest

from lauschi_catalog.reference import (
    ReferenceEpisode,
    ReferenceIndex,
    ReferenceLine,
    ReferenceProduct,
    ReferenceSeries,
    _key,
)

NAMES = {
    157: "Kommissar Kugelblitz",
    108: "Bibi Blocksberg",
    92: "TKKG Junior",
    5: "TKKG",
}
KUGELBLITZ = ReferenceSeries(
    157,
    "Kommissar Kugelblitz",
    [
        ReferenceLine(
            "Hörspiele zu den Büchern",
            [
                ReferenceEpisode("1", "Die rote Socke", 3674, product=1),
                ReferenceEpisode(None, "Sammelband", None),
            ],
        ),
        ReferenceLine("Musik", []),
    ],
)


def _product(
    product_id: int,
    title: str,
    *,
    author: str = "Kommissar Kugelblitz",
    line: tuple[str | None, str] | None = None,
    brand: str = "Kommissar Kugelblitz",
) -> ReferenceProduct:
    """A product of the search. ``line`` is (line name, number) for a
    product the index files under ``brand``, None for an unfiled one."""
    return ReferenceProduct(
        id=product_id,
        title=title,
        author=author,
        label="EUROPA mini",
        kind="RADIOPLAY",
        seconds=2880,
        categories=("Krimi",),
        brand=brand if line is not None else None,
        line=line[0] if line is not None else None,
        number=line[1] if line is not None else None,
        barcode=f"40297591603{product_id:02d}",
    )


PRODUCTS = [
    _product(1, "Die rote Socke", line=("Hörspiele zu den Büchern", "1")),
    _product(2, "Der grüne Schal"),
    _product(3, "Kugelblitz in London", author="Ursel Scheffler"),
    _product(4, "Blitz und Donner", author="Wetter für Kinder"),
    # filed under the brand, but the hit names no line
    _product(6, "Der blaue Hut", line=(None, "7")),
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


class FakeSource:
    """The index holding Kommissar Kugelblitz, counting its calls."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def names(self) -> dict[int, str]:
        self.calls.append("names")
        return dict(NAMES)

    def series(self, series_id: int) -> ReferenceSeries:
        self.calls.append(f"series {series_id}")
        assert series_id == 157
        return KUGELBLITZ

    def products(self, query: str) -> list[ReferenceProduct]:
        self.calls.append(f"products {query}")
        assert query == "Kommissar Kugelblitz"
        return list(PRODUCTS)

    def barcodes(self, series_id: int) -> dict[int, str]:
        self.calls.append(f"barcodes {series_id}")
        return {p.id: p.barcode for p in PRODUCTS}


def fake_source() -> FakeSource:
    return FakeSource()


def index() -> ReferenceIndex:
    return ReferenceIndex(fake_source(), use_cache=False)


def test_unconfigured_index_answers_without_a_source() -> None:
    idx = ReferenceIndex()
    assert idx.configured is False
    assert idx.find("TKKG") == []
    assert idx.lines_for("TKKG") is None
    assert idx.products("TKKG") == []
    assert idx.barcodes(157) == {}


def test_the_environment_names_the_source_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.py"
    source.write_text(
        "from tests.test_reference_index import FakeSource\n"
        "def source():\n"
        "    return FakeSource()\n"
    )
    monkeypatch.setenv("REFERENCE_INDEX_SOURCE", str(source))

    idx = ReferenceIndex(use_cache=False)

    assert idx.configured is True
    assert idx.find("tkkg") == [(5, "TKKG"), (92, "TKKG Junior")]


def test_a_source_path_that_does_not_load_is_an_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REFERENCE_INDEX_SOURCE", str(tmp_path / "missing.py"))
    with pytest.raises(FileNotFoundError):
        ReferenceIndex()


def test_exact_name_matches_come_before_partial_ones() -> None:
    assert index().find("tkkg") == [(5, "TKKG"), (92, "TKKG Junior")]
    assert index().find("Kommissar Kugelblitz")[0] == (157, "Kommissar Kugelblitz")
    assert index().find("Conni") == []


def test_lines_for_gives_the_best_matching_series() -> None:
    assert index().lines_for("kommissar kugelblitz") == KUGELBLITZ


def test_answers_are_cached_per_question(tmp_path: Path) -> None:
    source = fake_source()
    idx = ReferenceIndex(source, cache_root=tmp_path)

    for _ in range(2):
        idx.lines_for("Kommissar Kugelblitz")
        idx.products("Kommissar Kugelblitz")
        idx.barcodes(157)

    assert source.calls == [
        "names",
        "series 157",
        "products Kommissar Kugelblitz",
        "barcodes 157",
    ]
    assert ReferenceIndex(fake_source(), cache_root=tmp_path).series(157) == KUGELBLITZ


@pytest.mark.parametrize(
    ("name", "key"),
    [
        ("Die drei ??? Kids", "die drei kids"),
        ("Kommissar Kugelblitz ", "kommissar kugelblitz"),
        ("H2O – Plötzlich Meerjungfrau", "h2o plötzlich meerjungfrau"),
    ],
)
def test_matching_key_folds_case_punctuation_and_spacing(name: str, key: str) -> None:
    assert _key(name) == key


def test_a_brands_products_without_a_line() -> None:
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
