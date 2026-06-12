"""GET /api/cover/{provider}/{album_id} — on-demand album cover proxy.

Resolves the album's cover URL via the provider's album_details (which
is disk-cached, so each album hits the provider API at most once per
TTL) and redirects to the CDN image. Templates use this as a universal
img src so every album shows its real cover.
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


def _provider_with(image_url: str | None):
    provider = MagicMock()
    if image_url is None:
        provider.album_details.return_value = None
    else:
        detail = MagicMock()
        detail.image_url = image_url
        provider.album_details.return_value = detail
    return provider


def test_redirects_to_cdn_image(client):
    provider = _provider_with("https://cdn.example/cover.jpg")
    with patch("lauschi_catalog.web.routes.api._cover_provider", return_value=provider):
        resp = client.get("/api/cover/spotify/abc123", follow_redirects=False)
    assert resp.status_code == 302
    assert resp.headers["location"] == "https://cdn.example/cover.jpg"
    assert "max-age" in resp.headers.get("cache-control", "")
    provider.album_details.assert_called_once_with("abc123")


def test_404_when_album_has_no_image(client):
    provider = _provider_with(None)
    with patch("lauschi_catalog.web.routes.api._cover_provider", return_value=provider):
        resp = client.get("/api/cover/spotify/abc123", follow_redirects=False)
    assert resp.status_code == 404


def test_unknown_provider_is_rejected(client):
    resp = client.get("/api/cover/napster/abc123", follow_redirects=False)
    assert resp.status_code == 404
