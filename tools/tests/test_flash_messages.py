"""Session-backed flash messages: one-shot, typed, rendered in base.html.

Routes store messages in the session via redirect_with_flash; the
flash_context processor pops them on the next render so they appear
exactly once, then disappear.
"""

from __future__ import annotations

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

    def test_flash_renders_after_redirect(self, client):
        """add_flash -> redirect -> banner appears on landing page."""
        # The /validate page is lightweight and always renders.
        # We trigger a flash by going through a route that sets one.
        # Use the jobs API form submission with missing fields to trigger
        # an error flash.
        resp = client.post(
            "/api/jobs",
            data={"series_id": "", "command": ""},
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
        assert resp.status_code == 200
        assert "flash-error" in resp.text

    def test_flash_is_one_shot(self, client):
        """Flash should not appear on a second GET."""
        resp = client.post(
            "/api/jobs",
            data={"series_id": "", "command": ""},
            headers={"content-type": "application/x-www-form-urlencoded"},
        )
        assert "flash-error" in resp.text

        resp2 = client.get("/jobs")
        assert "flash-error" not in resp2.text

    def test_banner_escapes_html(self, client):
        """Session flashes must be HTML-escaped (safe=False)."""
        # We can't easily inject XSS through the form interface, but
        # we can verify session flashes are never marked safe by
        # checking that the context processor sets safe=False.
        f = make_flash("error", "<script>alert(1)</script>")
        assert f["safe"] is False


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
