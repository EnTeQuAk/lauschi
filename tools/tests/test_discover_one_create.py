"""Tests that discover_one routes creation through add_series and
respects deleted.yaml."""

from __future__ import annotations

import pytest

from lauschi_catalog.catalog import discover_ops
from lauschi_catalog.catalog import loader as catalog_loader
from lauschi_catalog.catalog.discover_ops import (
    DiscoverMatch,
    _artist_to_match,
    discover_one,
)
from lauschi_catalog.providers.base import Artist


def _artist(
    name: str, provider: str = "spotify", genres: list[str] | None = None
) -> Artist:
    return Artist(
        id=f"id_{name.lower().replace(' ', '_')}",
        name=name,
        provider=provider,
        genres=genres or [],
    )


class _FakeProvider:
    name = "spotify"

    def __init__(self, candidates: list[Artist]) -> None:
        self._candidates = candidates

    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        return list(self._candidates)

    def artist_exists(self, _artist_id: str) -> bool:
        return True


def _patch_loader(monkeypatch, tmp_path: object, yaml_text: str = "series: []\n"):
    """Point all loader IO at the temp dir so tests are hermetic."""
    real_load_catalog = catalog_loader.load_catalog
    real_load_raw = catalog_loader.load_raw
    real_save_raw = catalog_loader.save_raw

    monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
    (tmp_path / "assets" / "catalog").mkdir(parents=True)
    yaml_path = tmp_path / "assets" / "catalog" / "series.yaml"
    yaml_path.write_text(yaml_text)
    (tmp_path / "assets" / "catalog" / "deleted.yaml").write_text("deleted: []\n")
    (tmp_path / "android").mkdir()
    (tmp_path / ".cache").mkdir()

    def load_catalog(_path=None):
        return real_load_catalog(yaml_path)

    def load_raw(_path=None):
        return real_load_raw(yaml_path)

    def save_raw(data, _path=None):
        real_save_raw(data, yaml_path)

    monkeypatch.setattr("lauschi_catalog.catalog.loader.load_catalog", load_catalog)
    monkeypatch.setattr("lauschi_catalog.catalog.loader.load_raw", load_raw)
    monkeypatch.setattr("lauschi_catalog.catalog.loader.save_raw", save_raw)
    monkeypatch.setattr(discover_ops, "load_catalog", load_catalog)
    monkeypatch.setattr(discover_ops, "load_raw", load_raw)
    monkeypatch.setattr(discover_ops, "save_raw", save_raw)
    monkeypatch.setattr("lauschi_catalog.catalog.add_ops.load_catalog", load_catalog)
    monkeypatch.setattr("lauschi_catalog.catalog.series_ops.load_catalog", load_catalog)
    monkeypatch.setattr("lauschi_catalog.catalog.series_ops.load_raw", load_raw)

    return yaml_path


@pytest.mark.anyio
async def test_discover_one_creates_series_with_sure_matches(tmp_path, monkeypatch):
    _patch_loader(monkeypatch, tmp_path)

    provider = _FakeProvider([_artist("Die Playmos")])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is True
    assert result.new_series_id == "die_playmos"
    assert result.written is True
    yaml = catalog_loader.load_raw(tmp_path / "assets" / "catalog" / "series.yaml")
    assert any(e.get("id") == "die_playmos" for e in yaml.get("series", []))


@pytest.mark.anyio
async def test_discover_one_skips_creation_when_only_weak_match(tmp_path, monkeypatch):
    _patch_loader(monkeypatch, tmp_path)

    provider = _FakeProvider([_artist("Playmobil Soundtrack", genres=["Kinder"])])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is False
    assert result.written is False


@pytest.mark.anyio
async def test_discover_one_refuses_deleted_series(tmp_path, monkeypatch):
    """A deleted series id should not be re-created by discover --write."""
    _patch_loader(monkeypatch, tmp_path)
    (tmp_path / "assets" / "catalog" / "deleted.yaml").write_text(
        "deleted:\n  - id: die_playmos\n    title: Die Playmos\n    reason: test\n"
    )

    provider = _FakeProvider([_artist("Die Playmos")])

    result = discover_one(
        "Die Playmos",
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.created_new is False
    assert result.written is False


def test_artist_to_match_confidence_is_exact_or_substring():
    """The confidence used by the write path only trusts exact/substring."""
    exact = _artist("Die Playmos")
    assert _artist_to_match(exact, "exact").confidence == "exact"
    assert _artist_to_match(exact, "substring").confidence == "substring"
    assert _artist_to_match(exact, "genre").confidence == "genre"


def test_discover_match_model_stores_confidence():
    m = DiscoverMatch(
        provider="spotify",
        artist_id="id_die_playmos",
        artist_name="Die Playmos",
        confidence="exact",
    )
    assert m.confidence == "exact"
