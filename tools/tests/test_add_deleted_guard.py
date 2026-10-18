"""Pin that ``catalog-add`` refuses to re-introduce a deleted id
without ``--force-readd``.

The whole point of the deletion log is to catch a future curate agent
(or tired human) silently re-adding a series we deliberately dropped.
These tests pin the contract from the add side.
"""

import pytest
from click.testing import CliRunner

from lauschi_catalog.catalog import add_ops as add_ops_mod
from lauschi_catalog.catalog import deleted as deleted_mod
from lauschi_catalog.catalog.io import load_raw
from lauschi_catalog.commands import add as add_mod
from tests.conftest import ScratchCatalog


@pytest.fixture
def env(scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch):
    """Fresh catalog + empty deletion log + neutered providers."""
    scratch_catalog.write_series()
    # add() constructs real providers when keys are present (mise loads
    # the developer .env), and it imports the classes by name, so the
    # stubs below must land on add's own binding and the keys must be
    # absent, or a unit test ends up searching the live Spotify API.
    for key in ("SPOTIFY_CLIENT_ID", "SPOTIFY_CLIENT_SECRET"):
        monkeypatch.delenv(key, raising=False)

    # Pre-seed the log with a deletion.
    deleted_mod.record_deletion(
        "tom_turbo",
        "Tom Turbo",
        "No streaming presence",
        path=scratch_catalog.deleted_log,
    )

    # Skip provider calls — add() asks confirmation when none are found,
    # which would hang on stdin. We need providers that just return None.
    class _NoSpotify:
        def __init__(self):
            raise SystemExit

    class _NoApple:
        def __init__(self):
            raise FileNotFoundError

    monkeypatch.setattr(add_ops_mod, "load_catalog", lambda: [])
    return scratch_catalog


def test_add_refuses_to_readd_deleted_id(env, monkeypatch):
    runner = CliRunner()
    # Disable all providers so we don't try to hit the network or pause
    # for confirmation prompts.

    def _no_spotify(*_a, **_kw):
        raise SystemExit

    def _no_apple(*_a, **_kw):
        raise FileNotFoundError

    monkeypatch.setattr(add_mod, "SpotifyProvider", _no_spotify)
    monkeypatch.setattr(add_mod, "AppleMusicProvider", _no_apple)

    result = runner.invoke(
        add_mod.add,
        ["Tom Turbo", "--id", "tom_turbo", "--no-analyse", "--dry-run"],
    )
    assert result.exit_code == 1
    assert "previously deleted" in result.output
    assert "No streaming presence" in result.output
    assert "--force-readd" in result.output


def test_add_with_force_readd_clears_log_entry(env, monkeypatch, tmp_path):
    """--force-readd lets the operator re-introduce the series and
    removes the deletion log entry as part of the same write."""
    runner = CliRunner()

    # Stub providers so add() doesn't pause for confirmation. We pass
    # --no-analyse and a non-dry-run, so the add path will try to
    # write series.json. Providers raise during construction → add()
    # falls through with "no providers" and confirms via click prompt.

    def _no_spotify(*_a, **_kw):
        raise SystemExit

    def _no_apple(*_a, **_kw):
        raise FileNotFoundError

    monkeypatch.setattr(add_mod, "SpotifyProvider", _no_spotify)
    monkeypatch.setattr(add_mod, "AppleMusicProvider", _no_apple)

    # Auto-confirm the "no providers, add anyway?" prompt.
    result = runner.invoke(
        add_mod.add,
        ["Tom Turbo", "--id", "tom_turbo", "--no-analyse", "--force-readd"],
        input="y\n",
    )
    assert result.exit_code == 0, result.output

    # The deletion log no longer contains tom_turbo.
    assert deleted_mod.is_deleted("tom_turbo", env.deleted_log) is None

    # The new entry landed in the test catalog, not the real repo one.
    # add_series_entry resolves the file via paths.catalog_path()
    # at call time; an unpatched paths module silently appends a
    # tom_turbo stub to the real series.json on every test run.
    data = load_raw(env.series_json)
    assert any(e["id"] == "tom_turbo" for e in data["series"])
