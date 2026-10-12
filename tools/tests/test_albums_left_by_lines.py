"""A main series is told which albums its sub-series saw and left.

A sub-series curates the shared page first and takes its albums. What
the main series is shown afterwards is what every sub-series left. Not
knowing that, the main series called such an album "the sub-series'",
and it shipped in neither entry (Hexe Lilli: Im wilden Wilden Westen).
"""

import json
from pathlib import Path

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    albums_left_by_lines,
    batch_prompt,
    build_batch_prompt,
)
from lauschi_catalog.catalog.models import CatalogEntry
from tests.factories import album_record, curation, discovered_album

MAIN = CatalogEntry(id="lilli", title="Hexe Lilli")
ERSTLESER = CatalogEntry(
    id="lilli_erstleser", title="Hexe Lilli: Erstleser", split_from="lilli"
)
KINOFILM = CatalogEntry(
    id="lilli_kinofilm", title="Hexe Lilli (Kinofilm)", split_from="lilli"
)


@pytest.fixture
def family(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    """The main series, a curated sub-series and one that never ran."""
    monkeypatch.setattr(curate_ops, "load_catalog", lambda: [MAIN, ERSTLESER, KINOFILM])
    monkeypatch.setattr(
        curate_ops, "curation_path", lambda sid: tmp_path / f"{sid}.json"
    )
    (tmp_path / "lilli_erstleser.json").write_text(
        json.dumps(
            curation(
                series_id="lilli_erstleser",
                albums=[
                    album_record("geb", title="Feiert Geburtstag"),
                    album_record(
                        "west",
                        title="Im wilden Wilden Westen",
                        include=False,
                        exclude_reason="sub_series_bleed",
                    ),
                    album_record(
                        "west",
                        provider="apple_music",
                        title="Folge 2: im wilden Wilden Westen",
                        include=False,
                        exclude_reason="sub_series_bleed",
                    ),
                    album_record(
                        "karaoke",
                        title="Feiert Geburtstag (Karaoke)",
                        include=False,
                        exclude_reason="format_variant",
                    ),
                ],
            )
        )
    )
    return tmp_path


def test_a_sub_series_left_what_it_called_another_line(family: Path) -> None:
    """Not what it took, and not what it found unwanted in its own line."""
    assert albums_left_by_lines("lilli") == {
        "Hexe Lilli: Erstleser": {("spotify", "west"), ("apple_music", "west")}
    }


def test_a_sub_series_that_never_ran_has_left_nothing(family: Path) -> None:
    assert "Hexe Lilli (Kinofilm)" not in albums_left_by_lines("lilli")


def test_a_sub_series_and_a_series_without_any_have_no_lines(family: Path) -> None:
    assert albums_left_by_lines("lilli_erstleser") == {}
    assert albums_left_by_lines("unknown") == {}
    assert albums_left_by_lines(None) == {}


def _prompt(lines: list[str]) -> str:
    return build_batch_prompt(
        series_title="Hexe Lilli",
        pattern=None,
        progress_text="Progress: 0 included, 0 excluded.",
        rolling="",
        structural_hints=[],
        sibling_titles=["Hexe Lilli: Erstleser"],
        lines=lines,
        batch_num=1,
        n_batches=1,
        n_albums=1,
        albums_xml="<album/>",
    )


def test_the_main_series_reads_which_lines_curated_before_it() -> None:
    prompt = _prompt(["Hexe Lilli: Erstleser"])

    assert (
        "These lines of the series curated this page before you and took "
        "their albums:\n  - Hexe Lilli: Erstleser\n"
        "An album marked `<left_by>` was seen by that line and not taken. "
        "`<not_left_by>` names the lines it can still belong to, or `none` "
        "(see 'Curating a series that has split-off lines').\n"
    ) in prompt
    assert prompt.index("<left_by>") < prompt.index("Batch 1/1")


def test_a_series_without_curated_lines_reads_nothing_about_them() -> None:
    assert "left_by" not in _prompt([])


def _batch(left_by_lines: dict[str, set[tuple[str, str]]]) -> str:
    return batch_prompt(
        [
            discovered_album("spotify", "west", "Im wilden Wilden Westen"),
            discovered_album("spotify", "mandolan", "Die Reise nach Mandolan"),
            discovered_album("spotify", "new", "Hexe Lilli und der Mondstein"),
        ],
        [],
        series_title="Hexe Lilli",
        pattern=None,
        seen_details={},
        run_facts={},
        sibling_titles=[],
        line_of=None,
        left_by_lines=left_by_lines,
        batch_num=1,
        n_batches=1,
    )


def test_an_album_carries_the_lines_that_left_it_and_those_that_did_not() -> None:
    """Every line that curated the page is named on every album, as one
    that left it or one that did not. Which line an album can still
    belong to is then written down, and no name has to be missed."""
    prompt = _batch(
        {
            "Hexe Lilli: Erstleser": {("spotify", "west"), ("spotify", "mandolan")},
            "Hexe Lilli (Kinofilm)": {("spotify", "west")},
        }
    )

    west, mandolan, new = prompt.split("<album ")[1:]
    assert (
        "  <left_by>Hexe Lilli (Kinofilm)</left_by>\n"
        "  <left_by>Hexe Lilli: Erstleser</left_by>\n"
        "  <not_left_by>none</not_left_by>\n"
    ) in west
    assert (
        "  <left_by>Hexe Lilli: Erstleser</left_by>\n"
        "  <not_left_by>Hexe Lilli (Kinofilm)</not_left_by>\n"
    ) in mandolan
    assert "<left_by>" not in new
    assert (
        "  <not_left_by>Hexe Lilli (Kinofilm)</not_left_by>\n"
        "  <not_left_by>Hexe Lilli: Erstleser</not_left_by>\n"
    ) in new
    assert "  - Hexe Lilli (Kinofilm)\n  - Hexe Lilli: Erstleser\n" in prompt


def test_a_line_that_left_nothing_is_still_named_on_every_album() -> None:
    """A line whose curation excludes none of these albums as another
    line's has curated the page all the same."""
    prompt = _batch({"Hexe Lilli (Kinofilm)": set()})

    for album in prompt.split("<album ")[1:]:
        assert "  <not_left_by>Hexe Lilli (Kinofilm)</not_left_by>\n" in album
        assert "<left_by>" not in album


def test_albums_of_a_series_without_curated_lines_carry_no_marker() -> None:
    assert "left_by" not in _batch({})
