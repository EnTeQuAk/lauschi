"""Tests for catalog/validate_ops.py L5 album-existence checks.

Apple Music re-releases content under new album IDs and detaches albums
from artist pages. Discography membership alone reported live albums as
missing (Coco, Encanto, Eule findet den Beat), so the album check must
fall back to a direct album lookup before declaring an ID gone.
"""

from __future__ import annotations

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.catalog.validate_ops import validate_l5
from lauschi_catalog.providers import Album


def _album(aid: str, name: str = "Album") -> Album:
    return Album(id=aid, name=name, provider="apple_music")


class FakeProvider:
    """Minimal CatalogProvider stand-in for validate_l5."""

    name = "apple_music"

    def __init__(self, discography: list[Album], existing: dict[str, Album]):
        self._discography = discography
        self._existing = existing
        self.album_lookups: list[str] = []

    def artist_albums(self, artist_id: str) -> list[Album]:
        return self._discography

    def album_details(self, album_id: str) -> Album | None:
        self.album_lookups.append(album_id)
        return self._existing.get(album_id)


def _entry(artist_ids: list[str], album_ids: list[str]) -> CatalogEntry:
    return CatalogEntry(
        id="test_series",
        title="Test Series",
        providers={
            "apple_music": ProviderConfig(
                artist_ids=artist_ids,
                album_ids=album_ids,
                has_albums=bool(album_ids),
            ),
        },
    )


def test_album_in_discography_counts_as_found():
    provider = FakeProvider([_album("111")], {})
    result = validate_l5(_entry(["a1"], ["111"]), provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (1, 1)
    assert result.unmatched == []
    # No direct lookup needed when the discography already contains it.
    assert provider.album_lookups == []


def test_album_missing_from_discography_but_live_counts_as_found():
    # The Eule/Coco/Encanto case: album exists, artist page doesn't list it.
    provider = FakeProvider([_album("111")], {"222": _album("222")})
    result = validate_l5(_entry(["a1"], ["111", "222"]), provider)
    assert (result.matched, result.total) == (2, 2)
    assert result.unmatched == []
    assert provider.album_lookups == ["222"]


def test_album_gone_entirely_reported_missing():
    # The TiRiLi case: ID removed from the store, re-released under a new ID.
    provider = FakeProvider([_album("111")], {})
    result = validate_l5(_entry(["a1"], ["111", "999"]), provider)
    assert (result.matched, result.total) == (1, 2)
    assert result.unmatched == ["999"]


def test_album_check_runs_without_artist_ids():
    # The peter_pan_kinofilm case: configured albums, no artist page.
    provider = FakeProvider([], {"333": _album("333")})
    result = validate_l5(_entry([], ["333"]), provider)
    assert result.album_check is True
    assert (result.matched, result.total) == (1, 1)
    assert result.unmatched == []


def test_no_pattern_no_albums_returns_empty():
    provider = FakeProvider([_album("111")], {})
    result = validate_l5(_entry(["a1"], []), provider)
    assert result.total == 0
    assert result.album_check is False
