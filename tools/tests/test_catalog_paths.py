"""Tests for catalog.paths module."""

from lauschi_catalog.catalog import paths


def test_repo_root_is_a_directory():
    root = paths.repo_root()
    assert root.is_dir()
    assert (root / "tools").is_dir()


def test_series_yaml_path_under_repo_root():
    p = paths.series_yaml_path()
    assert p.name == "series.yaml"
    assert "assets" in str(p)


def test_curation_dir_under_assets():
    d = paths.curation_dir()
    assert d.name == "curation"
    assert "assets" in str(d)


def test_curation_path_builds_json_filename():
    p = paths.curation_path("die_drei_fragezeichen")
    assert p.name == "die_drei_fragezeichen.json"
    assert p.parent == paths.curation_dir()


def test_series_lock_path():
    p = paths.series_lock_path()
    assert p.name == ".series.yaml.lock"


def test_deleted_yaml_path():
    p = paths.deleted_yaml_path()
    assert p.name == "deleted.yaml"


def test_cache_dir():
    p = paths.cache_dir("spotify")
    assert p.name == "spotify"
    assert ".cache" in str(p)


def test_log_dir():
    p = paths.log_dir()
    assert p.name == "catalog"
    assert "logs" in str(p)


def test_repo_root_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    assert paths.repo_root() == tmp_path


def test_cover_cache_dir():
    d = paths.cover_cache_dir()
    assert d.name == ".covers"
    assert "assets" in str(d)


def test_cover_cache_path():
    p = paths.cover_cache_path("benjamin_bluemchen")
    assert p.name == "benjamin_bluemchen.json"
    assert p.parent == paths.cover_cache_dir()


def test_paths_functions_resolve_at_call_time(monkeypatch, tmp_path):
    """No module-level constants remain: env set after import still wins."""
    import importlib

    reloaded = importlib.reload(paths)
    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    assert (
        reloaded.series_yaml_path() == tmp_path / "assets" / "catalog" / "series.yaml"
    )
    assert reloaded.curation_dir() == tmp_path / "assets" / "catalog" / "curation"
