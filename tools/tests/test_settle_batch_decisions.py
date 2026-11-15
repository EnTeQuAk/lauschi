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
