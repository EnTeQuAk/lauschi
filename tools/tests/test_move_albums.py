"""Moving an album from one entry of a family to another, by hand.

A curation run decides which line an album belongs to. When a person
knows better, the album has to change hands in both curations at once:
the entry that gives it up records who owns it now, and the entry that
takes it includes it with the number its own pattern reads from the
title. An album must never end up in two entries, or in none.
"""

import json
from pathlib import Path

import pytest
from click.testing import CliRunner
from ruamel.yaml import YAML

from lauschi_catalog.catalog import merge_ops
from lauschi_catalog.catalog.partition import bleed_owner
from lauschi_catalog.commands.edit import edit
from tests.factories import album_record

MAIN_PATTERN = r"^Folge (\d+):"


@pytest.fixture
def catalog(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    """A main series, its Erstleser sub-series and an unrelated series."""
    root = tmp_path / "assets" / "catalog"
    (root / "curation").mkdir(parents=True)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    artists = {
        "spotify": {"artist_ids": ["lilli"]},
        "apple_music": {"artist_ids": ["am"]},
    }
    YAML().dump(
        {
            "series": [
                {
                    "id": "lilli",
                    "title": "Hexe Lilli",
                    "episode_pattern": MAIN_PATTERN,
                    "providers": artists,
                },
                {
                    "id": "lilli_erstleser",
                    "title": "Hexe Lilli: Erstleser",
                    "split_from": "lilli",
                    "episode_pattern": r"^Folge (\d+): .*\(Erstleser\)",
                    "providers": artists,
                },
                {"id": "other", "title": "Other", "providers": {}},
            ]
        },
        root / "series.yaml",
    )
    _write(
        root,
        "lilli",
        [
            album_record("ep2", title="Folge 2: Zauberquatsch", episode_num=2),
            album_record(
                "haus",
                provider="apple_music",
                title="Folge 8: zaubert Hausaufgaben",
                episode_num=8,
                release_date="1996",
                decided_by="kimi-k2.6",
            ),
            album_record(
                "geb",
                title="Feiert Geburtstag",
                include=False,
                exclude_reason="sub_series_bleed",
                notes="No pattern match",
            ),
        ],
    )
    _write(
        root,
        "lilli_erstleser",
        [
            album_record(
                "schultag", title="Folge 9: Schultag (Erstleser)", episode_num=9
            ),
            album_record(
                "geb",
                title="Feiert Geburtstag",
                include=False,
                exclude_reason="sub_series_bleed",
                notes="Belongs to 'lilli'",
            ),
        ],
    )
    _write(root, "other", [])
    return root


def _write(root: Path, series_id: str, albums: list[dict]) -> None:
    path = root / "curation" / f"{series_id}.json"
    path.write_text(json.dumps({"id": series_id, "title": series_id, "albums": albums}))


def _rows(root: Path, series_id: str) -> dict[tuple[str, str], dict]:
    data = json.loads((root / "curation" / f"{series_id}.json").read_text())
    return {(a["provider"], a["album_id"]): a for a in data["albums"]}


def test_the_album_changes_hands_in_both_curations(catalog: Path) -> None:
    result = merge_ops.move_albums(
        "lilli", "lilli_erstleser", [("apple_music", "haus")]
    )

    assert result.ok and result.moved == 1
    given_up = _rows(catalog, "lilli")[("apple_music", "haus")]
    assert given_up["include"] is False
    assert given_up["exclude_reason"] == "sub_series_bleed"
    assert given_up["episode_num"] is None
    assert bleed_owner(given_up["notes"]) == "lilli_erstleser"
    assert given_up["decided_by"] == "operator"

    taken = _rows(catalog, "lilli_erstleser")[("apple_music", "haus")]
    assert taken["include"] is True
    assert "exclude_reason" not in taken
    assert taken["title"] == "Folge 8: zaubert Hausaufgaben"
    assert taken["release_date"] == "1996"
    assert taken["decided_by"] == "operator"


def test_the_number_is_read_with_the_new_entrys_pattern(catalog: Path) -> None:
    """The old edition's "Folge 8" is not a number of the Erstleser line,
    whose pattern asks for the line's marker in the title."""
    merge_ops.move_albums("lilli", "lilli_erstleser", [("apple_music", "haus")])

    assert (
        _rows(catalog, "lilli_erstleser")[("apple_music", "haus")]["episode_num"]
        is None
    )


def test_an_album_both_entries_had_excluded_goes_to_the_new_owner(
    catalog: Path,
) -> None:
    merge_ops.move_albums("lilli", "lilli_erstleser", [("spotify", "geb")])

    assert bleed_owner(_rows(catalog, "lilli")[("spotify", "geb")]["notes"]) == (
        "lilli_erstleser"
    )
    taken = _rows(catalog, "lilli_erstleser")[("spotify", "geb")]
    assert taken["include"] is True
    assert bleed_owner(taken.get("notes")) is None


def test_a_sub_series_gives_an_album_back_to_the_main_series(catalog: Path) -> None:
    result = merge_ops.move_albums(
        "lilli_erstleser", "lilli", [("spotify", "schultag")]
    )

    assert result.ok
    assert _rows(catalog, "lilli")[("spotify", "schultag")]["episode_num"] == 9
    given_up = _rows(catalog, "lilli_erstleser")[("spotify", "schultag")]
    assert given_up["include"] is False
    assert bleed_owner(given_up["notes"]) == "lilli"


def test_other_albums_are_left_alone(catalog: Path) -> None:
    before = _rows(catalog, "lilli")[("spotify", "ep2")]

    merge_ops.move_albums("lilli", "lilli_erstleser", [("apple_music", "haus")])

    assert _rows(catalog, "lilli")[("spotify", "ep2")] == before


@pytest.mark.parametrize(
    ("source", "target", "album", "problem"),
    [
        ("lilli", "other", ("apple_music", "haus"), "not in one family"),
        ("lilli", "lilli", ("apple_music", "haus"), "must be different"),
        ("lilli", "nope", ("apple_music", "haus"), "'nope' is not in the catalog"),
        (
            "lilli",
            "lilli_erstleser",
            ("spotify", "unknown"),
            "spotify:unknown is in neither",
        ),
    ],
)
def test_a_move_that_cannot_be_right_changes_nothing(
    catalog: Path, source: str, target: str, album: tuple[str, str], problem: str
) -> None:
    before = {sid: _rows(catalog, sid) for sid in ("lilli", "lilli_erstleser", "other")}

    result = merge_ops.move_albums(source, target, [("spotify", "ep2"), album])

    assert not result.ok
    assert problem in (result.error or "")
    assert {sid: _rows(catalog, sid) for sid in before} == before


class TestEditMove:
    def test_the_command_moves_the_albums_and_says_what_to_apply(
        self, catalog: Path
    ) -> None:
        result = CliRunner().invoke(
            edit,
            ["move", "lilli", "lilli_erstleser", "apple_music:haus", "spotify:geb"],
        )

        assert result.exit_code == 0, result.output
        assert "Moved 2 album(s) from lilli to lilli_erstleser" in result.output
        assert "apply lilli" in result.output
        assert "apply lilli_erstleser" in result.output
        assert _rows(catalog, "lilli_erstleser")[("spotify", "geb")]["include"] is True

    def test_a_refused_move_fails_the_command(self, catalog: Path) -> None:
        result = CliRunner().invoke(
            edit, ["move", "lilli", "other", "apple_music:haus"]
        )

        assert result.exit_code == 1
        assert "not in one family" in result.output

    def test_an_album_needs_its_provider(self, catalog: Path) -> None:
        result = CliRunner().invoke(edit, ["move", "lilli", "lilli_erstleser", "haus"])

        assert result.exit_code != 0
        assert "provider:album_id" in result.output
