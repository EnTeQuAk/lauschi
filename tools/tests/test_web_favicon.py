"""The catalog web UI ships the lauschi icon as its favicon.

Browsers fetch /favicon.ico from the site root on their own, so that
path must answer directly; the pages also link the icon explicitly.
"""

from fastapi.testclient import TestClient


def test_root_favicon_is_served_as_ico(web_client: TestClient) -> None:
    resp = web_client.get("/favicon.ico")
    assert resp.status_code == 200
    assert resp.headers["content-type"] in {"image/x-icon", "image/vnd.microsoft.icon"}
    assert resp.content[:4] == b"\x00\x00\x01\x00", "not an ICO file"


def test_apple_touch_icon_is_served(web_client: TestClient) -> None:
    resp = web_client.get("/static/apple-touch-icon.png")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
