"""POST /catalog/{series_id}/delete removes a series via the web UI.

Delegates to series_ops.delete_series (same path as the CLI delete
command): series.yaml entry removed, curation JSON deleted, deletion
recorded in deleted.yaml.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.catalog.series_ops import DeleteResult
from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


def test_delete_calls_series_ops_and_redirects(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series",
        return_value=DeleteResult(ok=True),
    ) as mock_delete:
        resp = client.post(
            "/catalog/christian/delete",
            data={
                "reason": "Contributor-only artist; albums belong to Kikaninchen",
                "confirm": "1",
            },
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/catalog"
    mock_delete.assert_called_once_with(
        "christian",
        reason="Contributor-only artist; albums belong to Kikaninchen",
    )


def test_delete_success_flash_appears_on_redirect(client):
    """Following the redirect should render the one-shot flash banner."""
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series",
        return_value=DeleteResult(ok=True),
    ):
        resp = client.post(
            "/catalog/christian/delete",
            data={"reason": "test", "confirm": "1"},
        )
    assert resp.status_code == 200
    assert "flash-success" in resp.text
    assert "Deleted christian" in resp.text


def test_delete_requires_reason(client):
    with patch("lauschi_catalog.web.routes.catalog.delete_series") as mock_delete:
        resp = client.post(
            "/catalog/christian/delete",
            data={"reason": "   "},
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/catalog/christian/edit"
    mock_delete.assert_not_called()


def test_delete_unknown_series_shows_error(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series",
        return_value=DeleteResult(ok=False, error="series 'nope' not found"),
    ):
        resp = client.post(
            "/catalog/nope/delete",
            data={"reason": "whatever", "confirm": "1"},
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/catalog/nope/edit"


def test_first_post_asks_for_confirmation(client):
    """Without confirm=1 the route renders an Inyoka-style confirm flash
    that re-submits the same form, instead of deleting."""
    with patch("lauschi_catalog.web.routes.catalog.delete_series") as mock_delete:
        resp = client.post(
            "/catalog/5_geschwister/delete",
            data={"reason": "test reason"},
            follow_redirects=False,
        )
    assert resp.status_code == 200
    assert "flash-warning" in resp.text
    assert 'name="confirm" value="1"' in resp.text
    assert 'value="test reason"' in resp.text
    mock_delete.assert_not_called()


def test_flash_is_one_shot(client):
    """Flash messages should disappear after the first display (no F5 replay)."""
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series",
        return_value=DeleteResult(ok=True),
    ):
        resp = client.post(
            "/catalog/christian/delete",
            data={"reason": "test", "confirm": "1"},
        )
    assert "flash-success" in resp.text

    resp2 = client.get("/catalog")
    assert "flash-success" not in resp2.text
    assert "Deleted" not in resp2.text
