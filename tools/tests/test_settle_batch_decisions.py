"""What the catalog ships is what is left after the deterministic steps
that follow the model's batch answers.

`settle_batch_decisions` runs them in one fixed order: the provider's
titles are restored, a sub-series leaves its doubt to the main series
and claims the twins of what it took, the main series is named as the
owner of the rest, a main series keeps what it ships of a line without
an entry, and then the numbers are read from titles, tracks and twins. The curate flow calls it, and so do the evals, so that a case is
scored on what would ship.
"""

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import AlbumDecision, settle_batch_decisions
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.partition import AWAITS_SPLIT
from tests.factories import decision

MAIN = CatalogEntry(id="hexe_lilli", title="Hexe Lilli", providers={})
SUB = CatalogEntry(
    id="hexe_lilli_erstleser",
    title="Hexe Lilli Erstlesergeschichten",
    split_from="hexe_lilli",
    providers={"spotify": ProviderConfig(artist_ids=["a"], album_ids=[], albums=[])},
)
PATTERN = r"^Folge (\d+):"


def _page(*albums: tuple[str, str, str, str]) -> list[dict]:
    return [
        {"provider": p, "id": i, "name": name, "release_date": date}
        for p, i, name, date in albums
    ]


def test_a_sub_series_settles_doubt_then_twins_then_owner_then_numbers() -> None:
    unsure = decision(
        "sonder",
        include=True,
        confidence="medium",
        notes="Sonderband, maybe the main line",
        title="Sonderband",
        release_date="2015-01-01",
    )
    unsure.decided_by = "kimi-k2.6"
    claimed = decision(
        "sp-geb", title="Folge 2: Feiert Geburtstag", release_date="2015-02-01"
    )
    twin = decision(
        "am-geb",
        provider="apple_music",
        include=False,
        exclude_reason="sub_series_bleed",
        title="Folge 2: Feiert Geburtstag",
        release_date="2015-02-01",
    )
    echoed = decision("sp-vamp", title="Folge 9: Vampir", episode_num=9)
    decisions = [unsure, claimed, twin, echoed]

    settle_batch_decisions(
        decisions,
        discovered=_page(
            ("spotify", "sonder", "Sonderband", "2015-01-01"),
            ("spotify", "sp-geb", "Folge 2: Feiert Geburtstag", "2015-02-01"),
            ("apple_music", "am-geb", "Folge 2: Feiert Geburtstag", "2015-02-01"),
            ("spotify", "sp-vamp", "Folge 3: Und der Vampir", "2015-03-01"),
        ),
        pattern=PATTERN,
        entry=SUB,
        line_of=MAIN.title,
        series_names=["Hexe Lilli Erstlesergeschichten"],
        seen_details={},
    )

    # doubt goes to the main series, and only then is the owner named
    assert unsure.include is False
    assert curate_ops.bleed_owner(unsure.notes) == "hexe_lilli"
    # the twin of a claimed title is claimed, and numbered like it
    assert twin.include is True and twin.episode_num == 2
    assert claimed.episode_num == 2
    # the provider's title wins over what the model echoed, and so does
    # the number that title carries
    assert echoed.title == "Folge 3: Und der Vampir"
    assert echoed.episode_num == 3


def test_a_main_series_keeps_its_unsure_includes_and_ownerless_bleed() -> None:
    unsure = decision(
        "special", include=True, confidence="medium", notes="no number", title="Special"
    )
    bleed = decision(
        "kids", include=False, exclude_reason="sub_series_bleed", title="Junior 1"
    )

    settle_batch_decisions(
        [unsure, bleed],
        discovered=_page(
            ("spotify", "special", "Special", "2015-01-01"),
            ("spotify", "kids", "Junior 1", "2015-01-01"),
        ),
        pattern=PATTERN,
        entry=MAIN,
        line_of=None,
        series_names=["Hexe Lilli"],
        seen_details={},
    )

    assert unsure.include is True
    assert curate_ops.bleed_owner(bleed.notes) is None


def _shipping(series_id: str, *album_ids: str, split_from: str | None = None):
    return CatalogEntry(
        id=series_id,
        title="Die Schule der magischen Tiere",
        split_from=split_from,
        providers={
            "spotify": ProviderConfig(
                artist_ids=["a"],
                album_ids=list(album_ids),
                albums=[{"id": album_id} for album_id in album_ids],
            )
        },
    )


def _left_to_a_line(album_id: str, title: str, **kw: str) -> AlbumDecision:
    d = decision(
        album_id,
        include=False,
        exclude_reason=kw.get("exclude_reason", "sub_series_bleed"),
        title=title,
        notes=kw.get("notes", "Endlich Ferien line, own numbering"),
    )
    d.decided_by = kw.get("decided_by", "deepseek-v4-pro:0813")
    return d


def _settle(decisions: list[AlbumDecision], entry: CatalogEntry) -> None:
    settle_batch_decisions(
        decisions,
        discovered=_page(*(("spotify", d.album_id, d.title, "") for d in decisions)),
        pattern=PATTERN,
        entry=entry,
        line_of="Die Schule der magischen Tiere" if entry.split_from else None,
        series_names=["Die Schule der magischen Tiere"],
        seen_details={},
    )


def test_a_main_series_keeps_what_it_ships_of_a_line_without_an_entry() -> None:
    """Both full runs of 2026-10-13 left 25 shipped "Endlich Ferien" albums
    of Die Schule der magischen Tiere to a line the catalog has no entry
    for. Until a person accepts that split they would ship nowhere."""
    shipped = _left_to_a_line("ferien-3", "Folge 3: Endlich Ferien - Henry und Leander")
    unshipped = _left_to_a_line(
        "ferien-9", "Folge 9: Endlich Ferien - Hatice und Mette-Maja"
    )

    _settle(
        [shipped, unshipped], _shipping("die_schule_der_magischen_tiere", "ferien-3")
    )

    assert shipped.include is True and shipped.exclude_reason is None
    assert shipped.decided_by == AWAITS_SPLIT
    assert shipped.notes == (
        "Stays in this series until its line has an entry. "
        "Endlich Ferien line, own numbering"
    )
    # it is numbered like every other album the series includes
    assert shipped.episode_num == 3
    # what the series does not ship waits for the split, as before
    assert unshipped.include is False
    assert unshipped.exclude_reason == "sub_series_bleed"
    assert unshipped.decided_by == "deepseek-v4-pro:0813"


@pytest.mark.parametrize(
    ("left", "split_from"),
    [
        pytest.param({}, "die_schule_der_magischen_tiere", id="a sub-series"),
        pytest.param({"decided_by": "operator"}, None, id="excluded by hand"),
        pytest.param(
            {"notes": "Belongs to 'die_schule_der_magischen_tiere_endlich_ferien'"},
            None,
            id="another entry owns it",
        ),
        pytest.param({"exclude_reason": "duplicate"}, None, id="another reason"),
    ],
)
def test_a_shipped_album_still_leaves(
    left: dict[str, str], split_from: str | None
) -> None:
    album = _left_to_a_line("ferien-3", "Folge 3: Endlich Ferien", **left)

    _settle([album], _shipping("some_entry", "ferien-3", split_from=split_from))

    assert album.include is False
    assert album.decided_by != AWAITS_SPLIT


def _box_and_singles(
    box: str, singles: dict[int, bool]
) -> tuple[AlbumDecision, dict[int, AlbumDecision]]:
    """A box and the singles beside it on one Apple Music page, all of one
    day, as the Feuerwehrmann Sam re-release of 2026-05-29 lists them."""
    day = "2026-05-29"
    the_box = decision("box", provider="apple_music", title=box, release_date=day)
    the_box.decided_by = "operator"
    alone = {
        number: decision(
            f"single-{number}",
            provider="apple_music",
            title=f"Folge {number}: Story {number}",
            release_date=day,
            include=shipped,
            exclude_reason=None if shipped else "partial_release",
        )
        for number, shipped in singles.items()
    }
    return the_box, alone


@pytest.mark.parametrize(
    ("box", "singles", "number"),
    [
        pytest.param(
            "Folgen 151-154: Hilfspolizist James",
            {151: True, 152: True, 153: True},
            154,
            id="its first episode ships alone",
        ),
        pytest.param(
            "Folgen 27-30: Die Königin von Halloween",
            {28: True, 29: True, 30: True},
            27,
            id="its first episode is only in the box",
        ),
        pytest.param(
            "Folgen 151-154: Hilfspolizist James",
            {151: False, 152: True, 153: True},
            151,
            id="a single that does not ship",
        ),
    ],
)
def test_a_box_beside_singles_carries_the_first_episode_only_it_releases(
    box: str, singles: dict[int, bool], number: int
) -> None:
    """Apple Music has Feuerwehrmann Sam 151 to 153 alone, and 154 only in
    the box "Folgen 151-154", which ships for it. Numbered with its first
    episode the box took 151 from the single, and the number-reuse settle
    then cleared one of the two, whichever came first on the page."""
    the_box, alone = _box_and_singles(box, singles)

    settle_batch_decisions(
        [*alone.values(), the_box],
        discovered=_page(
            *(
                ("apple_music", d.album_id, d.title, d.release_date or "")
                for d in [the_box, *alone.values()]
            )
        ),
        pattern=PATTERN,
        entry=CatalogEntry(id="feuerwehrmann_sam", title="Feuerwehrmann Sam"),
        line_of=None,
        series_names=["Feuerwehrmann Sam"],
        seen_details={},
    )

    assert the_box.episode_num == number
    shipped = {n: d.episode_num for n, d in alone.items() if d.include}
    assert shipped == {n: n for n in shipped}


def _by_hand(album_id: str, title: str, number: int | None, **kw: str) -> AlbumDecision:
    d = decision(album_id, title=title, episode_num=number, **kw)
    d.decided_by = "operator"
    return d


def _settle_numbers(
    decisions: list[AlbumDecision], seen_details: dict[str, dict] | None = None
) -> None:
    settle_batch_decisions(
        decisions,
        discovered=_page(
            *(
                (d.provider, d.album_id, d.title, d.release_date or "")
                for d in decisions
            )
        ),
        pattern=PATTERN,
        entry=CatalogEntry(id="spirit", title="Spirit"),
        line_of=None,
        series_names=["Spirit"],
        seen_details=seen_details or {},
    )


def test_a_number_a_person_set_against_the_title_stays() -> None:
    """Apple Music titles Spirit's third story "Folge 2" as well, and a
    person gave it the 3 its Spotify twin carries. Read from the title
    again, it took the real Folge 2's number, and the reuse settle then
    cleared one of the two."""
    real = _by_hand(
        "real-2",
        "Folge 2: Die rätselhafte Karte",
        2,
        provider="apple_music",
        release_date="2018-10-12",
    )
    mislabelled = _by_hand(
        "turo",
        "Folge 2: Ein Pferd für Turo",
        3,
        provider="apple_music",
        release_date="2018-11-09",
    )

    _settle_numbers([real, mislabelled])

    assert (real.episode_num, mislabelled.episode_num) == (2, 3)


def test_a_number_a_person_gave_a_title_without_one_stays() -> None:
    """The Wilde Hühner readings name no book number, in the title or the
    tracks, so a person numbers them by book. A pattern a later run reads
    must not drop that as unsupported."""
    book = _by_hand("klassenfahrt", "Die Wilden Hühner auf Klassenfahrt", 2)
    tracks = {"spotify:klassenfahrt": {"tracks": [{"name": "Kapitel 1"}]}}

    _settle_numbers([book], tracks)

    assert book.episode_num == 2


def test_a_newer_story_does_not_take_a_number_a_person_set() -> None:
    """The newest story keeps a reused number, unless a person gave it to
    the older one."""
    older = _by_hand("older", "Die alte Geschichte", 5, release_date="2010-01-01")
    newer = decision(
        "newer", title="Folge 5: Die neue Geschichte", release_date="2024-01-01"
    )

    _settle_numbers([older, newer])

    assert older.episode_num == 5
    assert newer.episode_num is None


def _copy(album_id: str, title: str, barcode: str, **kw: object) -> AlbumDecision:
    d = decision(album_id, title=title, release_date="2022-11-17", **kw)  # type: ignore[arg-type]
    d.barcode = barcode
    return d


def _settle_page(decisions: list[AlbumDecision], entry: CatalogEntry) -> None:
    settle_batch_decisions(
        decisions,
        discovered=_page(
            *(
                (d.provider, d.album_id, d.title, d.release_date or "")
                for d in decisions
            )
        ),
        pattern=PATTERN,
        entry=entry,
        line_of=None,
        series_names=[entry.title],
        seen_details={},
    )


def test_one_release_ships_once_whatever_its_copies_are_titled() -> None:
    """Spotify put Die Playmos 81 under a second id, titled "Prinzessin in
    höchster Not" next to the "Prinzessin in Not" the series ships. One
    barcode, one release: the copy that ships stays."""
    shipped = _copy("old-id", "Folge 81: Prinzessin in Not", "4260229665008")
    moved = _copy("new-id", "Folge 81: Prinzessin in höchster Not", "4260229665008")
    entry = CatalogEntry(
        id="die_playmos",
        title="Die Playmos",
        providers={
            "spotify": ProviderConfig(
                albums=[{"id": "old-id", "title": shipped.title, "episode": 81}]
            )
        },
    )

    _settle_page([moved, shipped], entry)

    assert shipped.include and shipped.episode_num == 81
    assert not moved.include and moved.exclude_reason == "duplicate"


def test_a_persons_decision_on_a_release_holds_for_its_other_copies() -> None:
    """Heidi's 1970s Hörspielserie: a person shipped the High German Folge
    1 and excluded the Swiss German one. Spotify moved both to new ids,
    the Swiss German one without "(Schwizer Dütsch)" in its title."""
    high_german = _copy("hd", "Folge 1: Heidi kommt zum Alm-Öhi", "4066004023557")
    high_german.decided_by = "operator"
    swiss = _copy(
        "ch",
        "Folge 1: Heidi kommt zum Alm-Öhi (Schwizer Dütsch)",
        "4066004026329",
        include=False,
        exclude_reason="sub_series_bleed",
        notes="Schwizer-Dütsch (Swiss German) version of the same episode",
    )
    swiss.decided_by = "operator"
    swiss_moved = _copy("ch-new", "Folge 1: Heidi kommt zum Alm-Öhi", "4066004026329")
    high_german_moved = _copy(
        "hd-new", "Folge 1: Heidi kommt zum Alm-Öhi", "4066004023557"
    )
    entry = CatalogEntry(id="heidi_1970", title="Heidi")

    _settle_page([high_german, swiss, swiss_moved, high_german_moved], entry)

    assert high_german.include
    assert not swiss_moved.include
    assert swiss_moved.exclude_reason == "sub_series_bleed"
    assert not high_german_moved.include
    assert high_german_moved.exclude_reason == "duplicate"


@pytest.mark.parametrize(
    ("first", "second"),
    [
        pytest.param(("a", "spotify", ""), ("b", "spotify", ""), id="no barcode"),
        pytest.param(
            ("a", "spotify", "123"), ("b", "apple_music", "123"), id="two stores"
        ),
    ],
)
def test_copies_without_a_shared_barcode_on_one_store_both_stay(
    first: tuple[str, str, str], second: tuple[str, str, str]
) -> None:
    a = _copy(first[0], "Willi und die Wunder dieser Welt", first[2], provider=first[1])
    b = _copy(
        second[0],
        "Willi und die Wunder dieser Welt (Hörspiel)",
        second[2],
        provider=second[1],
    )

    _settle_page([a, b], CatalogEntry(id="willi", title="Willi wills wissen"))

    assert a.include and b.include


def _track_list(*albums: tuple[AlbumDecision, list[str]]) -> dict[str, dict]:
    return {
        f"{d.provider}:{d.album_id}": {"tracks": [{"name": n} for n in names]}
        for d, names in albums
    }


def _single(album_id: str, title: str, release_date: str) -> AlbumDecision:
    d = decision(
        album_id,
        include=False,
        exclude_reason="music_single",
        title=title,
        release_date=release_date,
    )
    d.decided_by = "deepseek-v4-pro:0813"
    return d


def _settle_music(
    decisions: list[AlbumDecision],
    seen_details: dict[str, dict],
    content_type: str = "music",
) -> None:
    settle_batch_decisions(
        decisions,
        discovered=_page(
            *(
                (d.provider, d.album_id, d.title, d.release_date or "")
                for d in decisions
            )
        ),
        pattern=None,
        entry=CatalogEntry(id="senta", title="Senta"),
        line_of=None,
        series_names=["Senta"],
        seen_details=seen_details,
        content_type=content_type,
    )


def test_a_single_ships_when_no_album_has_its_song() -> None:
    """Senta's singles mostly come back on an album, and those stay out.
    "Senta Klaus" is on none of them, so the single is its only release."""
    album = decision("hoch", title="Hoch die Hände Wochenende", release_date="2025")
    on_album = _single("liebe", "Liebesdusche", "2025-05-23")
    only_here = _single("klaus", "Senta Klaus", "2026-10-30")

    _settle_music(
        [album, on_album, only_here],
        _track_list(
            (album, ["Wut", "Liebesdusche (feat. Phela)", "Jetzt"]),
            (on_album, ["Liebesdusche - feat. Phela"]),
            (only_here, ["Senta Klaus"]),
        ),
    )

    assert not on_album.include
    assert only_here.include and only_here.exclude_reason is None
    assert only_here.decided_by == "only_release"


def test_two_singles_of_one_song_ship_once() -> None:
    first = _single("kbf", "Kinder brauchen Freiheit", "2026-01-09")
    community = _single(
        "kbf-c", "Kinder brauchen Freiheit (Community Version)", "2026-09-03"
    )

    _settle_music(
        [community, first],
        _track_list(
            (first, ["Kinder brauchen Freiheit"]),
            (community, ["Kinder brauchen Freiheit - Community Version"]),
        ),
    )

    assert first.include
    assert not community.include and community.exclude_reason == "music_single"


def test_a_single_leaves_once_an_album_brings_its_song() -> None:
    album = decision("glueck", title="Glückskeksgefühle", release_date="2026-09-18")
    single = decision("mathe", title="Mathe-Ma-Tik", release_date="2026-02-13")
    single.decided_by = "only_release"

    _settle_music(
        [album, single],
        _track_list((album, ["Mathe-Ma-Tik", "BFFI"]), (single, ["Mathe-Ma-Tik"])),
    )

    assert not single.include and single.exclude_reason == "music_single"


@pytest.mark.parametrize(
    ("content_type", "decided_by"),
    [
        pytest.param("hoerspiel", "deepseek-v4-pro:0813", id="not a music entry"),
        pytest.param("music", "operator", id="a person excluded it"),
    ],
)
def test_a_single_stays_out(content_type: str, decided_by: str) -> None:
    single = _single("klaus", "Senta Klaus", "2026-10-30")
    single.decided_by = decided_by

    _settle_music(
        [single], _track_list((single, ["Senta Klaus"])), content_type=content_type
    )

    assert not single.include


def test_a_single_whose_song_an_album_spells_differently_stays_out() -> None:
    """Hurra Kinderlieder's single "Hurra, wir schlafen" is the album's
    "Hurra wir schlafen": punctuation does not make another song."""
    album = decision("gute-nacht", title="Gute Nacht", release_date="2024")
    single = _single("hurra", "Hurra, wir schlafen!", "2024-05-01")

    _settle_music(
        [album, single],
        _track_list(
            (album, ["Hurra wir schlafen", "Kika-Tanzalarm"]),
            (single, ["Hurra, wir schlafen!"]),
        ),
    )

    assert not single.include
