"""Session-backed flash messages: one-shot, typed, rendered in base.html.

Routes store messages in the session via redirect_with_flash; the
flash_context processor pops them on the next render so they appear
exactly once, then disappear.
"""

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.flash import add_flash, make_flash
from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


class TestMakeFlash:
    def test_builds_plain_dict(self):
        f = make_flash("error", "oops")
        assert f == {"type": "error", "value": "oops", "safe": False}

    def test_builds_safe_dict(self):
        f = make_flash("warning", "<form>...</form>", safe=True)
        assert f["safe"] is True
        assert f["value"] == "<form>...</form>"


class TestBannerRendering:
    def test_no_banner_without_flash(self, client):
        resp = client.get("/jobs")
        assert 'class="flash' not in resp.text


class TestAddFlash:
    def test_stores_in_session(self):
        """add_flash stores messages in request.session['_flash']."""
        from unittest.mock import MagicMock

        request = MagicMock()
        request.session = {}
        add_flash(request, "success", "done")
        add_flash(request, "info", "synced")
        assert request.session["_flash"] == [
            {"type": "success", "value": "done"},
            {"type": "info", "value": "synced"},
        ]
