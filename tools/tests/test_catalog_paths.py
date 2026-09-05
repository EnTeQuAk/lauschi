"""Tests for catalog.paths module.

Every path is a function of the repo root at call time, so an env
override set after import still wins; the table pins each file's name
and the directory family it lives under.
"""

import importlib

import pytest

from lauschi_catalog.catalog import paths


def test_repo_root_is_a_directory():
    root = paths.repo_root()
    assert root.is_dir()
    assert (root / "tools").is_dir()


@pytest.mark.parametrize(
    ("build", "name", "under"),
    [
        pytest.param(paths.series_yaml_path, "series.yaml", "assets", id="series.yaml"),
        pytest.param(paths.curation_dir, "curation", "assets", id="curation dir"),
        pytest.param(
            lambda: paths.curation_path("die_drei_fragezeichen"),
            "die_drei_fragezeichen.json",
            "curation",
            id="curation file",
        ),
        pytest.param(
            paths.series_lock_path, ".series.yaml.lock", "assets", id="series lock"
        ),
        pytest.param(
            paths.deleted_yaml_path, "deleted.yaml", "assets", id="deleted.yaml"
        ),
        pytest.param(
            lambda: paths.cache_dir("spotify"), "spotify", ".cache", id="provider cache"
        ),
        pytest.param(paths.log_dir, "catalog", "logs", id="log dir"),
        pytest.param(paths.cover_cache_dir, ".covers", "assets", id="cover cache dir"),
        pytest.param(
            lambda: paths.cover_cache_path("benjamin_bluemchen"),
            "benjamin_bluemchen.json",
            ".covers",
            id="cover cache file",
        ),
    ],
)
def test_each_path_has_its_name_and_lives_under_its_family(build, name, under):
    p = build()
    assert p.name == name
    assert under in str(p)


def test_repo_root_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    assert paths.repo_root() == tmp_path


def test_paths_functions_resolve_at_call_time(monkeypatch, tmp_path):
    """No module-level constants remain: env set after import still wins."""
    reloaded = importlib.reload(paths)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    assert (
        reloaded.series_yaml_path() == tmp_path / "assets" / "catalog" / "series.yaml"
    )
    assert reloaded.curation_dir() == tmp_path / "assets" / "catalog" / "curation"
