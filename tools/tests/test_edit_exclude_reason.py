"""Pin that `catalog-edit exclude` records a human-supplied reason.

The earlier behaviour stamped the literal string "manual exclusion"
on every excluded album. Indistinguishable from a real curation
decision when a later review pass tries to figure out whether a drop
was intentional. The reason is now required.
"""

from __future__ import annotations

import json

import pytest
from click.testing import CliRunner

from lauschi_catalog.commands import edit as edit_mod


@pytest.fixture
def curation(monkeypatch, tmp_path):
    cur_dir = tmp_path / "curation"
    cur_dir.mkdir()
    path = cur_dir / "test_series.json"
    path.write_text(
        json.dumps(
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
        ),
    )
    monkeypatch.setattr(edit_mod, "CURATION_DIR", cur_dir)
    return path


def _read(path):
    return json.loads(path.read_text())["albums"][0]


def test_exclude_records_the_supplied_reason(curation):
    runner = CliRunner()
    result = runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "Wrong artist on this comp"],
    )
    assert result.exit_code == 0, result.output
    album = _read(curation)
    assert album["include"] is False
    assert album["exclude_reason"] == "Wrong artist on this comp"


def test_exclude_requires_reason(curation):
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


def test_exclude_overwrites_prior_reason(curation):
    """Re-excluding with a new reason replaces the old one. Useful when
    the original reason turned out to be wrong (see leo_lausemaus
    "duplicate of already-included" fix in 4b04c40)."""
    runner = CliRunner()
    runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "first reason"],
    )
    result = runner.invoke(
        edit_mod.exclude,
        ["test_series", "spotify-album-1", "-r", "actual real reason"],
    )
    assert result.exit_code == 0
    assert _read(curation)["exclude_reason"] == "actual real reason"
