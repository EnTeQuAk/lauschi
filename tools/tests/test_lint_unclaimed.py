"""Albums that every entry leaves to another line.

On a shared artist page each entry answers one question per album, is it
my line. When the main series says "the sub-series'" and the sub-series
says "the main series'", the album ships in neither, and no single
curation looks wrong. Only the catalog as a whole shows it.
"""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog.lint_ops import UnclaimedAlbum, unclaimed_albums
from lauschi_catalog.commands.lint import lint
from tests.factories import album_record, curation


def _bleed(album_id: str, title: str, provider: str = "spotify") -> dict:
    return album_record(
        album_id,
        provider=provider,
        title=title,
        include=False,
        exclude_reason="sub_series_bleed",
    )


MAIN = curation(
    series_id="lilli",
    title="Hexe Lilli",
    albums=[
        album_record("ep2", title="Folge 2: Zauberquatsch", episode_num=2),
        _bleed("knopf", "Und der kleine Eisbär Knöpfchen"),
        _bleed("geb", "Feiert Geburtstag"),
        album_record(
            "best",
            title="Das Beste von Hexe Lilli",
            include=False,
            exclude_reason="compilation",
        ),
    ],
)
ERSTLESER = curation(
    series_id="lilli_erstleser",
    title="Hexe Lilli: Erstleser",
    albums=[
        _bleed("ep2", "Folge 2: Zauberquatsch"),
        _bleed("knopf", "Und der kleine Eisbär Knöpfchen"),
        album_record("geb", title="Feiert Geburtstag"),
        _bleed("best", "Das Beste von Hexe Lilli"),
    ],
)
PAW = curation(
    series_id="paw",
    title="PAW Patrol",
    albums=[_bleed("dino", "Dino-Check 01", provider="apple_music")],
)


def test_an_album_each_entry_leaves_to_the_other_is_reported() -> None:
    assert unclaimed_albums([MAIN, ERSTLESER]) == [
        UnclaimedAlbum(
            provider="spotify",
            album_id="knopf",
            title="Und der kleine Eisbär Knöpfchen",
            seen_by=("lilli", "lilli_erstleser"),
        )
    ]


def test_what_one_entry_ships_or_excludes_for_its_content_is_settled() -> None:
    """Feiert Geburtstag ships in the sub-series, the episode in the main
    series, and the main series called the best-of a compilation."""
    reported = {a.album_id for a in unclaimed_albums([MAIN, ERSTLESER])}
    assert reported.isdisjoint({"geb", "ep2", "best"})


def test_a_line_without_an_entry_is_reported_on_a_page_of_its_own() -> None:
    assert unclaimed_albums([PAW]) == [
        UnclaimedAlbum(
            provider="apple_music",
            album_id="dino",
            title="Dino-Check 01",
            seen_by=("paw",),
        )
    ]


def test_the_same_id_on_two_providers_is_two_albums() -> None:
    other_store = curation(
        series_id="x",
        albums=[album_record("dino", provider="spotify", title="Dino-Check 01")],
    )
    assert [a.album_id for a in unclaimed_albums([PAW, other_store])] == ["dino"]


@pytest.fixture
def catalog(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    root = tmp_path / "assets" / "catalog" / "curation"
    root.mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    for data in (MAIN, ERSTLESER, PAW):
        (root / f"{data['id']}.json").write_text(json.dumps(data))
    return root


def test_lint_all_lists_the_unclaimed_albums_by_the_entries_that_saw_them(
    catalog: Path,
) -> None:
    result = CliRunner().invoke(lint, ["--all"])

    assert result.exit_code == 0, result.output
    assert "2 album(s) that every entry leaves to another line" in result.output
    assert "lilli, lilli_erstleser" in result.output
    assert "Und der kleine Eisbär Knöpfchen (spotify:knopf)" in result.output
    assert "Dino-Check 01 (apple_music:dino)" in result.output


def test_lint_of_one_series_lists_only_what_that_series_saw(catalog: Path) -> None:
    result = CliRunner().invoke(lint, ["lilli_erstleser"])

    assert result.exit_code == 0, result.output
    assert "Und der kleine Eisbär Knöpfchen (spotify:knopf)" in result.output
    assert "Dino-Check" not in result.output


def test_lint_says_nothing_about_unclaimed_albums_when_there_are_none(
    catalog: Path,
) -> None:
    (catalog / "lilli.json").unlink()
    (catalog / "paw.json").unlink()
    (catalog / "lilli_erstleser.json").write_text(
        json.dumps(curation(series_id="lilli_erstleser", albums=[album_record("geb")]))
    )

    result = CliRunner().invoke(lint, ["--all"])

    assert result.exit_code == 0, result.output
    assert "another line" not in result.output
