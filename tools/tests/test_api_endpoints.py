"""Tests for accept-artist and discover-preview API endpoints.

These test the endpoint logic (merge behavior, structured response
shape) by mocking the provider and catalog layers.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.providers import Artist
from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


def _entry(series_id: str, *, spotify_ids: list[str] | None = None) -> CatalogEntry:
    providers = {}
    if spotify_ids:
        providers["spotify"] = ProviderConfig(artist_ids=spotify_ids)
    return CatalogEntry(
        id=series_id,
        title=series_id.replace("_", " ").title(),
        providers=providers,
    )


class TestAcceptArtist:
    """POST /api/series/{id}/accept-artist"""

    def test_adds_new_artist_id(self, client, monkeypatch):
        entry = _entry("test_series", spotify_ids=["existing-id"])
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: entry if sid == "test_series" else None,
        )
        captured = {}

        def fake_update(*, updates):
            captured["updates"] = updates
            return 1

        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.update_provider_ids",
            fake_update,
        )
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.reload_catalog",
            lambda: None,
        )

        resp = client.post(
            "/api/series/test_series/accept-artist",
            json={"provider": "spotify", "artist_id": "new-id"},
        )
        assert resp.status_code == 200
        assert resp.json()["ok"] is True
        assert captured["updates"]["test_series"]["spotify"] == [
            "existing-id",
            "new-id",
        ]

    def test_does_not_duplicate_existing_id(self, client, monkeypatch):
        entry = _entry("test_series", spotify_ids=["existing-id"])
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: entry if sid == "test_series" else None,
        )
        captured = {}

        def fake_update(*, updates):
            captured["updates"] = updates
            return 1

        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.update_provider_ids",
            fake_update,
        )
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.reload_catalog",
            lambda: None,
        )

        resp = client.post(
            "/api/series/test_series/accept-artist",
            json={"provider": "spotify", "artist_id": "existing-id"},
        )
        assert resp.status_code == 200
        assert captured["updates"]["test_series"]["spotify"] == ["existing-id"]

    def test_returns_404_for_unknown_series(self, client, monkeypatch):
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: None,
        )
        resp = client.post(
            "/api/series/nonexistent/accept-artist",
            json={"provider": "spotify", "artist_id": "some-id"},
        )
        assert resp.status_code == 404

    def test_adds_first_id_for_new_provider(self, client, monkeypatch):
        entry = _entry("test_series")
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: entry if sid == "test_series" else None,
        )
        captured = {}

        def fake_update(*, updates):
            captured["updates"] = updates
            return 1

        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.update_provider_ids",
            fake_update,
        )
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.reload_catalog",
            lambda: None,
        )

        resp = client.post(
            "/api/series/test_series/accept-artist",
            json={"provider": "apple_music", "artist_id": "apple-123"},
        )
        assert resp.status_code == 200
        assert captured["updates"]["test_series"]["apple_music"] == ["apple-123"]


class TestDiscoverPreview:
    """POST /api/series/{id}/discover-preview"""

    def test_returns_candidates_and_best_match(self, client, monkeypatch):
        entry = _entry("bibi_blocksberg", spotify_ids=["123"])
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: entry if sid == "bibi_blocksberg" else None,
        )

        fake_provider = MagicMock()
        fake_provider.name = "spotify"
        fake_provider.search_artists.return_value = [
            Artist(
                id="sp-1",
                name="Bibi Blocksberg",
                provider="spotify",
                genres=["kinder"],
                followers=5000,
            ),
            Artist(
                id="sp-2",
                name="Bibi und Tina",
                provider="spotify",
                genres=["hörspiel"],
                followers=3000,
            ),
        ]
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api._init_providers",
            lambda: [fake_provider],
        )

        resp = client.post("/api/series/bibi_blocksberg/discover-preview")
        assert resp.status_code == 200

        data = resp.json()
        assert "candidates" in data
        assert "best_match" in data

        candidates = data["candidates"]["spotify"]
        assert len(candidates) == 2
        assert candidates[0]["id"] == "sp-1"
        assert candidates[0]["name"] == "Bibi Blocksberg"
        assert candidates[0]["confidence"] in ("exact", "substring", "genre", "weak")
        assert candidates[0]["genres"] == ["kinder"]
        assert candidates[0]["followers"] == 5000

        best = data["best_match"]["spotify"]
        assert best["id"] == "sp-1"
        assert best["name"] == "Bibi Blocksberg"

    def test_returns_404_for_unknown_series(self, client, monkeypatch):
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: None,
        )
        resp = client.post("/api/series/nonexistent/discover-preview")
        assert resp.status_code == 404

    def test_no_match_returns_null_best(self, client, monkeypatch):
        entry = _entry("obscure_series")
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api.get_series_by_id",
            lambda sid: entry if sid == "obscure_series" else None,
        )

        fake_provider = MagicMock()
        fake_provider.name = "spotify"
        fake_provider.search_artists.return_value = []
        monkeypatch.setattr(
            "lauschi_catalog.web.routes.api._init_providers",
            lambda: [fake_provider],
        )

        resp = client.post("/api/series/obscure_series/discover-preview")
        assert resp.status_code == 200
        data = resp.json()
        assert data["candidates"]["spotify"] == []
        assert data["best_match"]["spotify"] is None
