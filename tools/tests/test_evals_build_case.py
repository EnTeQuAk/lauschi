"""The builder that freezes an eval case from catalog, curation and cache.

Its I/O is a thin shell. What decides the content of a case file is
tested here: the series facts, which prior decisions a run would have,
the index evidence put next to an album, and the file's layout.
"""

import json
from typing import Any

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.reference import (
    ReferenceEpisode,
    ReferenceLine,
    ReferenceProduct,
    ReferenceSeries,
)
from tests.evals.build_case import (
    decided_rows,
    dump,
    evidence_from,
    index_evidence,
    never_asked,
    series_context,
    unfiled_evidence,
)
from tests.factories import album_record, entry

INDEX = ReferenceSeries(
    id=1,
    name="Hexe Lilli",
    lines=[
        ReferenceLine(
            "Klassiker",
            [
                ReferenceEpisode(
                    "Prequel", "Das Buch des Drachen (Wie alles begann)", 3300
                ),
                ReferenceEpisode("2", "Hexe Lilli macht Zauberquatsch", 2460),
            ],
        ),
        ReferenceLine(
            "Erstlesergeschichten",
            [
                ReferenceEpisode("1", "Zaubert Hausaufgaben", 1920),
                ReferenceEpisode("2", "Feiert Geburtstag", 3180),
            ],
        ),
    ],
)


class TestIndexEvidence:
    def test_a_store_number_and_the_brand_do_not_hide_the_story(self) -> None:
        assert index_evidence("Folge 8: zaubert Hausaufgaben", INDEX) == [
            "Erstlesergeschichten 1: Zaubert Hausaufgaben"
        ]
        assert index_evidence("Hexe Lilli feiert Geburtstag", INDEX) == [
            "Erstlesergeschichten 2: Feiert Geburtstag"
        ]

    def test_a_subtitle_in_brackets_is_ignored(self) -> None:
        assert index_evidence("Das Buch des Drachen", INDEX) == [
            "Klassiker Prequel: Das Buch des Drachen (Wie alles begann)"
        ]

    def test_a_title_the_index_does_not_list_has_no_evidence(self) -> None:
        assert index_evidence("Hexe Lilli und der kleine Delfin", INDEX) == []

    def test_a_title_that_is_only_the_brand_matches_nothing(self) -> None:
        assert index_evidence("Hexe Lilli", INDEX) == []

    def test_the_brand_shared_by_every_title_is_no_evidence(self) -> None:
        kokosnuss = ReferenceSeries(
            id=2,
            name="Der kleine Drache Kokosnuss",
            lines=[
                ReferenceLine(
                    "Hörspiele",
                    [
                        ReferenceEpisode(
                            "1", "Der kleine Drache Kokosnuss im Weltraum", 1
                        )
                    ],
                )
            ],
        )

        assert (
            index_evidence("Der kleine Drache Kokosnuss und die Schule", kokosnuss)
            == []
        )
        assert index_evidence(
            "Der kleine Drache Kokosnuss - Im Weltraum", kokosnuss
        ) == ["Hörspiele 1: Der kleine Drache Kokosnuss im Weltraum"]


def _shipping(series_id: str, title: str, **kw: Any) -> CatalogEntry:
    return CatalogEntry(
        id=series_id,
        title=title,
        providers={
            "spotify": ProviderConfig(
                artist_ids=["artist"], albums=[{"id": "sp1"}, {"id": "sp2"}]
            ),
            "apple_music": ProviderConfig(artist_ids=["am"], albums=[{"id": "am1"}]),
        },
        **kw,
    )


PAGE = [
    {"provider": "spotify", "id": "sp1", "name": "A", "release_date": "1994-04-27"},
    {"provider": "spotify", "id": "sp2", "name": "B", "release_date": "2022"},
    {"provider": "spotify", "id": "sp3", "name": "C", "release_date": None},
]


class TestSeriesContext:
    def test_a_main_series(self) -> None:
        main = _shipping(
            "lilli", "Hexe Lilli", episode_pattern=r"^Folge (\d+):", aliases=["Lilli"]
        )
        sibling = entry("lilli_kino", "Hexe Lilli (Kinofilm)", spotify=["artist"])

        assert series_context(main, [main, sibling], PAGE, None) == {
            "id": "lilli",
            "title": "Hexe Lilli",
            "content_type": "hoerspiel",
            "episode_pattern": r"^Folge (\d+):",
            "aliases": ["Lilli"],
            "discography_span_years": 28,
            "sibling_titles": ["Hexe Lilli (Kinofilm)"],
            "ships": [["apple_music", "am1"], ["spotify", "sp1"], ["spotify", "sp2"]],
        }

    def test_a_sub_series_names_its_main_series(self) -> None:
        main = entry("lilli", "Hexe Lilli", spotify=["artist"])
        sub = _shipping("lilli_erstleser", "Erstleser", split_from="lilli")

        context = series_context(sub, [main, sub], PAGE, "Hexe Lilli")

        assert context["split_from"] == "lilli"
        assert context["main_series_title"] == "Hexe Lilli"
        assert context["sibling_titles"] == ["Hexe Lilli"]

    def test_an_album_the_case_asks_about_is_not_shipped(self) -> None:
        """A run never asks about an album the entry ships. A case that
        asks about one treats it as new on the page, so the entry does
        not own it yet and the doubt rule applies to it."""
        sub = _shipping("lilli_erstleser", "Erstleser", split_from="lilli")

        context = series_context(
            sub, [sub], PAGE, "Hexe Lilli", asked={("spotify", "sp2")}
        )

        assert context["ships"] == [["apple_music", "am1"], ["spotify", "sp1"]]


class TestDecidedRows:
    CURATION = [
        album_record("asked", title="Folge 3: Gefragt", episode_num=3),
        album_record("own", title="Folge 1: Eigen", episode_num=1, release_date="2020"),
        album_record(
            "other",
            include=False,
            exclude_reason="sub_series_bleed",
            notes="Belongs to 'lilli'",
            decided_by="split",
        ),
        album_record(
            "by-hand",
            include=False,
            exclude_reason="compilation",
            decided_by="operator",
        ),
    ]

    def test_a_main_series_brings_every_decision_it_is_not_asked_about(self) -> None:
        rows = decided_rows(entry("lilli"), self.CURATION, {("spotify", "asked")})

        assert rows == [
            {
                "album_id": "own",
                "provider": "spotify",
                "title": "Folge 1: Eigen",
                "include": True,
                "episode_num": 1,
                "release_date": "2020",
            },
            {
                "album_id": "other",
                "provider": "spotify",
                "title": "other",
                "include": False,
                "episode_num": None,
                "release_date": None,
                "exclude_reason": "sub_series_bleed",
                "notes": "Belongs to 'lilli'",
            },
            {
                "album_id": "by-hand",
                "provider": "spotify",
                "title": "by-hand",
                "include": False,
                "episode_num": None,
                "release_date": None,
                "exclude_reason": "compilation",
                "decided_by": "operator",
            },
        ]

    def test_decisions_a_case_reopens_are_left_out(self) -> None:
        """A case about boxes must not tell the model that every other box
        was already excluded."""
        rows = decided_rows(
            entry("lilli"),
            self.CURATION,
            {("spotify", "asked")},
            reopened="^(other|by-)",
        )

        assert [row["album_id"] for row in rows] == ["own"]

    def test_a_sub_series_brings_only_what_it_includes(self) -> None:
        sub = entry("lilli_erstleser", split_from="lilli")

        rows = decided_rows(sub, self.CURATION, {("spotify", "asked")})

        assert [row["album_id"] for row in rows] == ["own"]


class TestDump:
    CASE = {
        "question": "?",
        "series": {"id": "s", "ships": [["spotify", "a"], ["spotify", "b"]]},
        "decided": [
            {"album_id": "a", "title": "Folge 1 [Remaster] {x}", "include": True}
        ],
        "albums": [
            {
                "id": "b",
                "tracks": [
                    {"name": "Teil 1", "duration_ms": 1},
                    {"name": "Teil 2", "duration_ms": 2},
                ],
                "expect": {
                    "include": False,
                    "exclude_reason": ["a", "b"],
                    "source": "x",
                },
            }
        ],
    }

    def test_the_file_reads_back_as_the_case(self) -> None:
        assert json.loads(dump(self.CASE)) == self.CASE

    def test_a_track_and_a_shipped_album_take_one_line_each(self) -> None:
        lines = dump(self.CASE).splitlines()

        assert '    {"name": "Teil 1", "duration_ms": 1},' in lines
        assert '   ["spotify", "a"],' in lines


def test_evidence_from_two_brands_names_the_brand() -> None:
    """Wieso? Weshalb? Warum? and its Junior books are two brands in the
    index and share one store page."""
    junior = ReferenceSeries(
        id=3,
        name="Hexe Lilli Junior",
        lines=[
            ReferenceLine("Junior", [ReferenceEpisode("4", "Feiert Geburtstag", 1)])
        ],
    )

    assert evidence_from("Hexe Lilli feiert Geburtstag", [INDEX, junior]) == [
        "Hexe Lilli > Erstlesergeschichten 2: Feiert Geburtstag",
        "Hexe Lilli Junior > Junior 4: Feiert Geburtstag",
    ]
    assert evidence_from("Hexe Lilli feiert Geburtstag", [INDEX]) == [
        "Erstlesergeschichten 2: Feiert Geburtstag"
    ]


def test_a_product_the_index_files_under_no_line_is_evidence_too() -> None:
    """Three states, not two: in a line, a product without a line, or
    not in the index at all."""
    unfiled = [
        ReferenceProduct(
            id=7,
            title="Und der kleine Eisbär Knöpfchen",
            author="Hexe Lilli",
            label="EUROPA mini",
            kind="RADIOPLAY",
            seconds=2880,
            categories=(),
            brand=None,
            line=None,
            number=None,
        )
    ]

    assert unfiled_evidence(
        "Hexe Lilli und der kleine Eisbär Knöpfchen", unfiled, "Hexe Lilli"
    ) == [
        "a product without a line: Und der kleine Eisbär Knöpfchen (EUROPA mini, 48 min)"
    ]
    assert unfiled_evidence("Hexe Lilli feiert Geburtstag", unfiled, "Hexe Lilli") == []


class TestNeverAsked:
    """A case must not ask what a run settles before the model is called."""

    MAIN = entry("ninjago", "Ninjago", spotify=["a"], episode_pattern=r"^Folge (\d+):")
    BOOKS = entry(
        "ninjago_buch",
        "Ninjago: Hörbücher",
        spotify=["a"],
        split_from="ninjago",
        episode_pattern=r"\(Band (\d+)\)",
    )
    PAGE = [
        {"provider": "spotify", "id": "band", "name": "Kai (Band 13)"},
        {"provider": "spotify", "id": "folge", "name": "Folge 100: Nichts los"},
        {
            "provider": "spotify",
            "id": "special",
            "name": "Special: Tag der Erinnerungen",
        },
    ]

    def test_a_sub_series_is_not_asked_what_one_pattern_of_the_family_matches(
        self,
    ) -> None:
        catalog = [self.MAIN, self.BOOKS]

        assert never_asked(self.PAGE, self.BOOKS, catalog) == [
            "spotify:band Kai (Band 13)",
            "spotify:folge Folge 100: Nichts los",
        ]

    def test_a_main_series_is_asked_about_its_own_matches(self) -> None:
        catalog = [self.MAIN, self.BOOKS]

        assert never_asked(self.PAGE, self.MAIN, catalog) == [
            "spotify:band Kai (Band 13)"
        ]
