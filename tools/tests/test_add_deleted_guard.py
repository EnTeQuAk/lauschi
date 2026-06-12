"""Pin that ``catalog-add`` refuses to re-introduce a deleted id
without ``--force-readd``.

The whole point of the deletion log is to catch a future curate agent
(or tired human) silently re-adding a series we deliberately dropped.
These tests pin the contract from the add side.
"""

from __future__ import annotations


import pytest
from click.testing import CliRunner
from ruamel.yaml import YAML

from lauschi_catalog.catalog import add_ops as add_ops_mod
from lauschi_catalog.catalog import deleted as deleted_mod
from lauschi_catalog.catalog import loader as loader_mod
from lauschi_catalog.catalog import paths as paths_mod
from lauschi_catalog.commands import add as add_mod

yaml = YAML()
yaml.preserve_quotes = True


@pytest.fixture
def env(monkeypatch, tmp_path):
    """Fresh catalog + empty deletion log + neutered providers."""
    series_yaml = tmp_path / "series.yaml"
    deleted_yaml = tmp_path / "deleted.yaml"
    with series_yaml.open("w") as f:
        yaml.dump({"series": []}, f)

    monkeypatch.setattr(loader_mod, "SERIES_YAML", series_yaml)
    monkeypatch.setattr(deleted_mod, "DELETED_YAML", deleted_yaml)
    # series_ops.add_series_entry resolves the file through
    # paths.series_yaml_path() at call time; without these patches the
    # force-readd test writes a tom_turbo stub into the REAL series.yaml.
    monkeypatch.setattr(paths_mod, "series_yaml_path", lambda: series_yaml)
    monkeypatch.setattr(
        paths_mod,
        "series_lock_path",
        lambda: tmp_path / ".series.yaml.lock",
    )

    # Pre-seed the log with a deletion.
    deleted_mod.record_deletion(
        "tom_turbo",
        "Tom Turbo",
        "No streaming presence",
        path=deleted_yaml,
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
    return {"series_yaml": series_yaml, "deleted_yaml": deleted_yaml}


def test_add_refuses_to_readd_deleted_id(env, monkeypatch):
    runner = CliRunner()
    # Disable all providers so we don't try to hit the network or pause
    # for confirmation prompts.
    import lauschi_catalog.providers.spotify as sp_mod
    import lauschi_catalog.providers.apple_music as am_mod

    def _no_spotify(*_a, **_kw):
        raise SystemExit

    def _no_apple(*_a, **_kw):
        raise FileNotFoundError

    monkeypatch.setattr(sp_mod, "SpotifyProvider", _no_spotify)
    monkeypatch.setattr(am_mod, "AppleMusicProvider", _no_apple)

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
    # write series.yaml. Providers raise during construction → add()
    # falls through with "no providers" and confirms via click prompt.
    import lauschi_catalog.providers.spotify as sp_mod
    import lauschi_catalog.providers.apple_music as am_mod

    def _no_spotify(*_a, **_kw):
        raise SystemExit

    def _no_apple(*_a, **_kw):
        raise FileNotFoundError

    monkeypatch.setattr(sp_mod, "SpotifyProvider", _no_spotify)
    monkeypatch.setattr(am_mod, "AppleMusicProvider", _no_apple)

    # Auto-confirm the "no providers, add anyway?" prompt.
    result = runner.invoke(
        add_mod.add,
        ["Tom Turbo", "--id", "tom_turbo", "--no-analyse", "--force-readd"],
        input="y\n",
    )
    assert result.exit_code == 0, result.output

    # The deletion log no longer contains tom_turbo.
    assert deleted_mod.is_deleted("tom_turbo", env["deleted_yaml"]) is None

    # The new entry landed in the test catalog, not the real repo one.
    # add_series_entry resolves the file via paths.series_yaml_path()
    # at call time; an unpatched paths module silently appends a
    # tom_turbo stub to the real series.yaml on every test run.
    data = yaml.load(env["series_yaml"])
    assert any(e["id"] == "tom_turbo" for e in data["series"])
