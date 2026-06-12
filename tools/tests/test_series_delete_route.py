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
            data={"reason": "Contributor-only artist; albums belong to Kikaninchen"},
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert resp.headers["location"] == "/catalog"
    mock_delete.assert_called_once_with(
        "christian",
        reason="Contributor-only artist; albums belong to Kikaninchen",
    )


def test_delete_requires_reason(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series"
    ) as mock_delete:
        resp = client.post(
            "/catalog/christian/delete",
            data={"reason": "   "},
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert "error" in resp.headers["location"]
    mock_delete.assert_not_called()


def test_delete_unknown_series_shows_error(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.delete_series",
        return_value=DeleteResult(ok=False, error="series 'nope' not found"),
    ):
        resp = client.post(
            "/catalog/nope/delete",
            data={"reason": "whatever"},
            follow_redirects=False,
        )
    assert resp.status_code == 303
    assert "error" in resp.headers["location"]
