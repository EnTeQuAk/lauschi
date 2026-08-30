"""Tests that discover only writes IDs it is sure of (T41)."""

from __future__ import annotations

from lauschi_catalog.catalog import discover_ops
from lauschi_catalog.catalog import loader as catalog_loader
from lauschi_catalog.catalog.discover_ops import (
    classify_match,
    match_artist,
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
    """Provider that returns the candidates we configure."""

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


def test_classify_match_exact_and_substring():
    exact = _artist("Die Playmos")
    sub = _artist("Die Playmos Hörspiele")
    unrelated = _artist("Playmobil")

    assert classify_match("Die Playmos", exact) == "exact"
    assert classify_match("Die Playmos", sub) == "substring"
    assert classify_match("Die Playmos", unrelated) == "weak"


def test_match_artist_stops_at_weak_when_multiple():
    """Two weak candidates should not return a match just because one exists."""
    candidates = [
        _artist("Various Hörspiele", genres=["Hörspiel"]),
        _artist("Kinderlieder ABC", genres=["Children"]),
    ]
    assert match_artist("Die Playmos", candidates) is None


def test_match_artist_single_candidate_is_weak():
    """A single weak candidate used to auto-win. It must not anymore."""
    candidates = [_artist("Random Artist", genres=["pop"])]
    assert match_artist("Die Playmos", candidates) is None


def test_match_artist_prefers_exact_over_substring():
    candidates = [
        _artist("Die Playmos Collection"),
        _artist("Die Playmos"),
    ]
    assert match_artist("Die Playmos", candidates).name == "Die Playmos"


def test_match_artist_substring_accepted_without_exact():
    candidates = [_artist("Die Playmos Hörspiele")]
    assert match_artist("Die Playmos", candidates).name == "Die Playmos Hörspiele"


def test_classify_match_genre_is_weak():
    """Genre-only confidence is the old behavior; classify still returns it,
    but the write path must treat it as not-sure.
    """
    artist = _artist("Completely Different Name", genres=["Hörspiel"])
    assert classify_match("Die Playmos", artist) == "genre"


def test_discover_all_only_writes_exact_and_substring(tmp_path, monkeypatch):
    """Weak and genre-only matches are reported but not written."""
    _patch_loader(
        monkeypatch,
        tmp_path,
        yaml_text="series:\n  - id: playmos\n    title: Die Playmos\n    providers:\n      spotify: {}\n",
    )

    exact = _artist("Die Playmos")
    weak = _artist("Random Artist", genres=["Hörspiel"])
    provider = _FakeProvider([exact, weak])

    monkeypatch.setattr(
        discover_ops, "update_provider_ids", lambda *, updates: len(updates)
    )

    result = discover_ops.discover_all(
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.found_total == 1
    assert "playmos" in result.updates
    assert result.updates["playmos"]["spotify"] == ["id_die_playmos"]
    assert result.written == 1


def test_discover_all_reports_weak_without_write(tmp_path, monkeypatch):
    """When every candidate is weak, no IDs are written."""
    _patch_loader(
        monkeypatch,
        tmp_path,
        yaml_text="series:\n  - id: playmos\n    title: Die Playmos\n    providers:\n      spotify: {}\n",
    )

    weak = _artist("Playmobil Soundtrack", genres=["Kinder"])
    provider = _FakeProvider([weak])

    monkeypatch.setattr(
        discover_ops, "update_provider_ids", lambda *, updates: len(updates)
    )

    result = discover_ops.discover_all(
        [provider],
        write=True,
        on_progress=lambda _m: None,
    )

    assert result.found_total == 0
    assert result.updates == {}
    assert result.written == 0
