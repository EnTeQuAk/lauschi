"""Which reference index series and lines each catalog entry is compared
against: by name, by the override file, and line by line inside a family."""

from pathlib import Path

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.reference_map import (
    load_overrides,
    map_catalog,
    same_story,
)
from lauschi_catalog.reference import ReferenceIndex


def _line(name: str, *titles: str) -> dict:
    return {
        "name": name,
        "episodes": [
            {"episodeNumber": str(n), "episodeTitle": t, "length": None}
            for n, t in enumerate(titles, start=1)
        ],
    }


SERIES = {
    10: {
        "id": 10,
        "name": "Hexe Lilli ",
        "seasons": [
            _line("Hörspiele", "Die Zauberschule", "Der Drache", "Die Piraten"),
            _line("Erstlesergeschichten", "Zaubert Hausaufgaben", "Feiert Geburtstag"),
            _line("Musik", "Lieder zum Zaubern"),
        ],
    },
    20: {
        "id": 20,
        "name": "Die drei !!!",
        "seasons": [_line("Fälle", "Tanz der Hexen")],
    },
    21: {
        "id": 21,
        "name": "Die drei ???",
        "seasons": [_line("Fälle", "Der Super-Papagei")],
    },
    30: {
        "id": 30,
        "name": "Lillis Abenteuer",
        "seasons": [_line("Folgen", "Im Dschungel")],
    },
}


def _fetch(url: str, params: dict | None) -> dict:
    if url.endswith("/series"):
        items = [{"id": sid, "name": s["name"]} for sid, s in SERIES.items()]
        return {"_embedded": {"series": items}, "page": {"totalPages": 1}}
    return SERIES[int(url.rsplit("/", 1)[1])]


def _index() -> ReferenceIndex:
    return ReferenceIndex("http://index.test", fetch=_fetch, use_cache=False)


def _entry(
    series_id: str,
    title: str,
    *titles: str,
    split_from: str | None = None,
    aliases: tuple[str, ...] = (),
) -> CatalogEntry:
    albums = [{"id": f"{series_id}-{i}", "title": t} for i, t in enumerate(titles)]
    return CatalogEntry(
        id=series_id,
        title=title,
        aliases=list(aliases),
        split_from=split_from,
        providers={"spotify": ProviderConfig(albums=albums)},
    )


LILLI = _entry(
    "hexe_lilli",
    "Hexe Lilli",
    "Folge 1: Die Zauberschule",
    "Folge 2: Der Drache",
    "Folge 3: Die Piraten",
)
ERSTLESER = _entry(
    "hexe_lilli_erstleser",
    "Hexe Lilli: Erstlesergeschichten",
    "Zaubert Hausaufgaben (Erstlesergeschichten)",
    split_from="hexe_lilli",
)


def test_a_family_takes_the_index_series_named_like_its_main_series() -> None:
    mapping = map_catalog([LILLI, ERSTLESER], _index(), {})
    assert mapping["hexe_lilli"].series is not None
    assert mapping["hexe_lilli"].series.id == 10
    assert mapping["hexe_lilli"].how == "name"


def test_each_line_goes_to_the_member_that_ships_most_of_it() -> None:
    mapping = map_catalog([LILLI, ERSTLESER], _index(), {})
    assert [line.name for line in mapping["hexe_lilli"].lines] == ["Hörspiele"]
    assert [line.name for line in mapping["hexe_lilli_erstleser"].lines] == [
        "Erstlesergeschichten"
    ]


def test_a_member_that_covers_no_line_says_so() -> None:
    kino = _entry(
        "hexe_lilli_kino", "Hexe Lilli: Kinofilm", "Der Film", split_from="hexe_lilli"
    )
    mapping = map_catalog([LILLI, kino], _index(), {})
    assert mapping["hexe_lilli_kino"].how == "no_line"
    assert mapping["hexe_lilli_kino"].lines == ()


def test_entries_of_a_dissolved_main_series_each_take_their_own_name() -> None:
    lilli = _entry("lilli", "Hexe Lilli", "Die Zauberschule", split_from="gone")
    ausrufezeichen = _entry(
        "die_drei_ausrufezeichen", "Die drei !!!", "Tanz der Hexen", split_from="gone"
    )
    mapping = map_catalog([lilli, ausrufezeichen], _index(), {})
    assert mapping["lilli"].series.id == 10  # type: ignore[union-attr]
    assert mapping["die_drei_ausrufezeichen"].series.id == 20  # type: ignore[union-attr]


def test_an_alias_names_the_index_series_too() -> None:
    lilli = _entry("lilli", "Lilli", "Im Dschungel", aliases=("Lillis Abenteuer",))
    assert map_catalog([lilli], _index(), {})["lilli"].series.id == 30  # type: ignore[union-attr]


def test_punctuation_keeps_two_index_series_apart() -> None:
    ausrufezeichen = _entry("die_drei_ausrufezeichen", "Die drei !!!", "Tanz der Hexen")
    mapping = map_catalog([ausrufezeichen], _index(), {})
    assert mapping["die_drei_ausrufezeichen"].series.id == 20  # type: ignore[union-attr]


def test_an_entry_without_an_index_series_of_its_name_is_unmapped() -> None:
    other = _entry("bobo", "Bobo Siebenschläfer", "Bobo im Zoo")
    mapping = map_catalog([other], _index(), {})
    assert mapping["bobo"].how == "unmapped"
    assert mapping["bobo"].series is None


def test_an_override_names_the_index_series_of_another_name() -> None:
    other = _entry("lillis_abenteuer", "Lilli erlebt", "Im Dschungel")
    mapping = map_catalog([other], _index(), {"lillis_abenteuer": {"series": 30}})
    assert mapping["lillis_abenteuer"].series.id == 30  # type: ignore[union-attr]
    assert mapping["lillis_abenteuer"].how == "map"


def test_an_override_says_the_index_has_nothing_for_an_entry() -> None:
    mapping = map_catalog([LILLI, ERSTLESER], _index(), {"hexe_lilli": None})
    assert mapping["hexe_lilli"].how == "not_in_index"
    assert mapping["hexe_lilli"].lines == ()
    assert mapping["hexe_lilli_erstleser"].how == "not_in_index"


def test_an_override_gives_a_member_the_lines_it_names() -> None:
    musik = _entry(
        "hexe_lilli_musik",
        "Hexe Lilli: Lieder",
        "Zauberlieder",
        split_from="hexe_lilli",
    )
    mapping = map_catalog(
        [LILLI, ERSTLESER, musik],
        _index(),
        {"hexe_lilli_musik": {"series": 10, "lines": ["Musik"]}},
    )
    assert [line.name for line in mapping["hexe_lilli_musik"].lines] == ["Musik"]
    assert mapping["hexe_lilli_musik"].how == "map"


def test_overrides_read_from_the_yaml_file(tmp_path: Path) -> None:
    path = tmp_path / "reference_map.yaml"
    path.write_text(
        "overrides:\n"
        "  bobo: null\n"
        "  lillis_abenteuer: 30\n"
        "  hexe_lilli_musik:\n"
        "    series: 10\n"
        "    lines: [Musik]\n"
    )
    assert load_overrides(path) == {
        "bobo": None,
        "lillis_abenteuer": {"series": 30},
        "hexe_lilli_musik": {"series": 10, "lines": ["Musik"]},
    }
    assert load_overrides(tmp_path / "missing.yaml") == {}


def test_same_story_folds_spelling_and_keeps_parts_apart() -> None:
    assert same_story("Folge 3: Die Piraten", "Die Piraten")
    assert same_story("Der Schlüssel", "Der Schluessel")
    assert not same_story("Die Party (Teil 1)", "Die Party (Teil 2)")
    assert not same_story("Der Drache", "Die Piraten")
