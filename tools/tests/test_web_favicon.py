"""The catalog web UI ships the lauschi icon as its favicon.

Browsers fetch /favicon.ico from the site root on their own, so that
path must answer directly; the pages also link the icon explicitly.
"""

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.main import app


@pytest.fixture
def client() -> TestClient:
    return TestClient(app)


def test_root_favicon_is_served_as_ico(client: TestClient) -> None:
    resp = client.get("/favicon.ico")
    assert resp.status_code == 200
    assert resp.headers["content-type"] in {"image/x-icon", "image/vnd.microsoft.icon"}
    assert resp.content[:4] == b"\x00\x00\x01\x00", "not an ICO file"


def test_apple_touch_icon_is_served(client: TestClient) -> None:
    resp = client.get("/static/apple-touch-icon.png")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"


def test_pages_link_the_favicon(client: TestClient) -> None:
    resp = client.get("/catalog")
    assert resp.status_code == 200
    assert '<link rel="icon" href="/static/favicon.ico">' in resp.text
    assert (
        '<link rel="apple-touch-icon" href="/static/apple-touch-icon.png">' in resp.text
    )
