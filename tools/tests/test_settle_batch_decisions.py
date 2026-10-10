"""What the catalog ships is what is left after the deterministic steps
that follow the model's batch answers.

`settle_batch_decisions` runs them in one fixed order: the provider's
titles are restored, a sub-series leaves its doubt to the main series
and claims the twins of what it took, the main series is named as the
owner of the rest, and then the numbers are read from titles, tracks and
twins. The curate flow calls it, and so do the evals, so that a case is
scored on what would ship.
"""

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import settle_batch_decisions
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
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
