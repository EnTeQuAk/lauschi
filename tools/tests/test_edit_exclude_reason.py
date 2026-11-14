"""Pin how `catalog-edit exclude` and `include` record a person's decision.

The reason is required and must be one of the curate reasons: a
re-curation reads every prior record into the curate model, and a reason
outside that vocabulary aborts the run. What the reason cannot say goes
into the note.
"""

import json
from pathlib import Path
from typing import Any

import pytest
from click.testing import CliRunner

from lauschi_catalog.commands import edit as edit_mod
from tests.conftest import ScratchCatalog


@pytest.fixture
def curation(scratch_catalog: ScratchCatalog) -> Path:
    return scratch_catalog.write_curation(
        {
            "id": "test_series",
            "title": "Test Series",
            "albums": [
                {
                    "album_id": "spotify-album-1",
                    "provider": "spotify",
                    "include": True,
                    "title": "Folge 1",
                },
            ],
        },
    )


def _read(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())["albums"][0]


def test_exclude_records_the_reason_and_the_note(curation: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(
        edit_mod.exclude,
        [
            "test_series",
            "spotify-album-1",
            "-r",
            "not_kids_content",
            "-n",
            "An album for adults, the label files it under Musik für Erwachsene",
        ],
    )
    assert result.exit_code == 0, result.output
    album = _read(curation)
    assert album["include"] is False
    assert album["exclude_reason"] == "not_kids_content"
    assert album["notes"] == (
        "An album for adults, the label files it under Musik für Erwachsene"
    )
    assert album["decided_by"] == "operator"


def test_exclude_requires_reason(curation: Path) -> None:
    """Click rejects the call without --reason so the operator has to
    say why. Same discipline as catalog-delete."""
    runner = CliRunner()
    result = runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1"],
    )
    assert result.exit_code == 2
    assert "reason" in result.output.lower()
    # The album stays untouched on a rejected call.
    album = _read(curation)
    assert album["include"] is True


def test_exclude_rejects_a_reason_the_next_curate_cannot_read(curation: Path) -> None:
    runner = CliRunner()
    result = runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "Wrong artist on this comp"],
    )
    assert result.exit_code == 2
    assert "not_kids_content" in result.output
    assert _read(curation) == {
        "album_id": "spotify-album-1",
        "provider": "spotify",
        "include": True,
        "title": "Folge 1",
    }


def test_exclude_overwrites_prior_reason(curation: Path) -> None:
    """Re-excluding with a new reason replaces the old one. Useful when
    the original reason turned out to be wrong (see leo_lausemaus
    "duplicate of already-included" fix in 4b04c40)."""
    runner = CliRunner()
    runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "duplicate"],
    )
    result = runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "format_variant"],
    )
    assert result.exit_code == 0
    assert _read(curation)["exclude_reason"] == "format_variant"


def test_include_replaces_the_note_of_the_exclusion(curation: Path) -> None:
    runner = CliRunner()
    runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "duplicate", "-n", "Same as Folge 1"],
    )
    result = runner.invoke(
        edit_mod.include,
        ["test_series", "spotify-album-1", "-n", "Another production of Folge 1"],
    )
    assert result.exit_code == 0, result.output
    album = _read(curation)
    assert album["include"] is True
    assert "exclude_reason" not in album
    assert album["notes"] == "Another production of Folge 1"


def test_include_without_a_note_keeps_the_one_there(curation: Path) -> None:
    runner = CliRunner()
    runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "duplicate", "-n", "Same as Folge 1"],
    )
    result = runner.invoke(edit_mod.include, ["test_series", "spotify-album-1"])
    assert result.exit_code == 0, result.output
    assert _read(curation)["notes"] == "Same as Folge 1"
