"""Which reference index series and lines each catalog entry is compared
against: by name, by the override file, and line by line inside a family."""

from datetime import date
from pathlib import Path

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.reference_map import (
    IndexEpisode,
    load_overrides,
    map_catalog,
    match_entry,
    same_story,
)
from lauschi_catalog.reference import ReferenceEpisode, ReferenceIndex, ReferenceLine


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
    # the index holds two series of one name; the second fits the albums
    40: {
        "id": 40,
        "name": "Sandmann",
        "seasons": [_line("Musik", "Sandmann, lieber Sandmann")],
    },
    41: {
        "id": 41,
        "name": "Sandmann",
        "seasons": [_line("Geschichten", "Pittiplatsch", "Moppi", "Schnatterinchen")],
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


def test_of_two_index_series_with_one_name_the_one_that_fits_the_albums_wins() -> None:
    sandmann = _entry(
        "sandmann", "Sandmann", "Pittiplatsch", "Moppi", "Schnatterinchen"
    )
    mapping = map_catalog([sandmann], _index(), {})
    assert mapping["sandmann"].series.id == 41  # type: ignore[union-attr]


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


def test_an_override_with_lines_on_a_main_series_gives_it_exactly_those() -> None:
    mapping = map_catalog(
        [LILLI, ERSTLESER], _index(), {"hexe_lilli": {"series": 10, "lines": ["Musik"]}}
    )
    assert [line.name for line in mapping["hexe_lilli"].lines] == ["Musik"]
    assert [line.name for line in mapping["hexe_lilli_erstleser"].lines] == [
        "Erstlesergeschichten"
    ]


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
    # one album holding both parts of a two-parter
    assert same_story(
        "Die großen Schlumpfspiele (Teil 1)", "Folge 35: Die großen Schlumpfspiele"
    )
    assert not same_story("Der Drache", "Die Piraten")


def _ep(line: str, number: int | None, title: str) -> IndexEpisode:
    return IndexEpisode(line=line, number=number, title=title)


def _lines(*episodes: IndexEpisode) -> tuple[ReferenceLine, ...]:
    by_line: dict[str, list[ReferenceEpisode]] = {}
    for ep in episodes:
        number = str(ep.number) if ep.number is not None else None
        by_line.setdefault(ep.line, []).append(ReferenceEpisode(number, ep.title, None))
    return tuple(ReferenceLine(name, eps) for name, eps in by_line.items())


def _shipping(*albums: tuple[str, int | None, str, str]) -> CatalogEntry:
    """(provider, number, title, release date) per shipped album."""
    providers: dict[str, ProviderConfig] = {}
    for i, (provider, number, title, released) in enumerate(albums):
        cfg = providers.setdefault(provider, ProviderConfig())
        cfg.albums.append(
            {"id": f"a{i}", "episode": number, "title": title, "release_date": released}
        )
    return CatalogEntry(id="lilli", title="Hexe Lilli", providers=providers)


TODAY = date(2026, 10, 17)


def test_a_story_under_its_number_matches_and_the_store_twins_are_one_album() -> None:
    entry = _shipping(
        ("spotify", 1, "Folge 1: Die Zauberschule", "2001-01-01"),
        ("apple_music", 1, "Folge 1: Die Zauberschule", "2001-01-01"),
    )
    result = match_entry(
        entry, _lines(_ep("Hörspiele", 1, "Die Zauberschule")), today=TODAY
    )
    assert result.matched == 1
    assert result.open_index == [] and result.open_ours == []


def test_numbers_and_titles_that_disagree_are_named() -> None:
    entry = _shipping(
        ("spotify", 2, "Folge 2: Die Piraten", "2001-01-01"),
        ("spotify", 3, "Folge 3: Im Zoo", "2001-01-01"),
    )
    lines = _lines(
        _ep("Hörspiele", 5, "Die Piraten"), _ep("Hörspiele", 3, "Der Drache")
    )
    result = match_entry(entry, lines, today=TODAY)
    [moved] = result.number_differs
    assert (moved.index.number, moved.ours.number) == (5, 2)
    [renamed] = result.title_differs
    assert (renamed.index.title, renamed.ours.title) == (
        "Der Drache",
        "Folge 3: Im Zoo",
    )


def test_an_album_that_lacks_the_index_number_still_matches() -> None:
    entry = _shipping(("spotify", None, "Die Zauberschule", "2001-01-01"))
    result = match_entry(
        entry, _lines(_ep("Hörspiele", 1, "Die Zauberschule")), today=TODAY
    )
    assert result.matched == 1
    assert [p.index.number for p in result.unnumbered] == [1]


def test_stories_bundled_in_one_album_or_named_by_its_tracks_count_as_shipped() -> None:
    entry = _shipping(
        ("spotify", None, "Die Zauberschule und Der Drache", "2001-01-01")
    )
    lines = _lines(
        _ep("Hörspiele", 1, "Die Zauberschule"),
        _ep("Hörspiele", 2, "Der Drache"),
        _ep("Hörspiele", 3, "Die Piraten"),
    )
    result = match_entry(
        entry, lines, today=TODAY, tracks=lambda: ["Die Piraten - Teil 1"]
    )
    assert (result.matched, result.bundled, result.in_tracks) == (1, 1, 1)
    assert result.open_index == []


def test_what_neither_side_matches_is_left_open() -> None:
    entry = _shipping(("spotify", None, "Lilli im Zirkus", "2001-01-01"))
    result = match_entry(entry, _lines(_ep("Hörspiele", 9, "Die Piraten")), today=TODAY)
    assert [ep.title for ep in result.open_index] == ["Die Piraten"]
    assert [a.title for a in result.open_ours] == ["Lilli im Zirkus"]


def test_albums_the_index_cannot_know_yet_are_set_aside() -> None:
    entry = _shipping(
        ("spotify", 4, "Folge 4: Lilli am Meer", "2026-09-30"),
        ("spotify", 12, "Folge 12: Lilli im Schnee", "2015-01-01"),
    )
    result = match_entry(entry, _lines(_ep("Hörspiele", 3, "Der Drache")), today=TODAY)
    assert sorted(a.number for a in result.newer) == [4, 12]
    assert result.open_ours == []
