"""Flash messages: typed, query-param based, rendered in base.html.

Routes redirect with repeated ?flash=type:value params via
flash.redirect_with_flash; a template context processor decodes them
into flash_messages for every page, and base.html renders one banner
per message. No sessions: the messages live in the URL they land on.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.flash import redirect_with_flash
from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


class TestRedirectHelper:
    def test_encodes_error_shorthand(self):
        resp = redirect_with_flash("/catalog", error="delete failed: not found")
        assert resp.status_code == 303
        assert (
            resp.headers["location"]
            == "/catalog?flash=error%3Adelete+failed%3A+not+found"
        )

    def test_encodes_message_shorthand_as_success(self):
        resp = redirect_with_flash("/jobs", message="job queued")
        assert resp.headers["location"] == "/jobs?flash=success%3Ajob+queued"

    def test_multiple_typed_messages(self):
        resp = redirect_with_flash(
            "/catalog", ("warning", "slow"), ("info", "synced")
        )
        loc = resp.headers["location"]
        assert "flash=warning%3Aslow" in loc
        assert "flash=info%3Asynced" in loc

    def test_plain_redirect_without_params(self):
        resp = redirect_with_flash("/catalog")
        assert resp.headers["location"] == "/catalog"

    def test_appends_to_existing_query(self):
        resp = redirect_with_flash("/catalog?tab=music", error="nope")
        assert resp.headers["location"] == "/catalog?tab=music&flash=error%3Anope"


class TestBannerRendering:
    def test_error_banner_renders_on_any_page(self, client):
        resp = client.get("/jobs?flash=error:already+running")
        assert resp.status_code == 200
        assert 'class="flash flash-error"' in resp.text
        assert "already running" in resp.text

    def test_multiple_banners_render(self, client):
        resp = client.get("/jobs?flash=success:job+queued&flash=info:synced")
        assert 'class="flash flash-success"' in resp.text
        assert 'class="flash flash-info"' in resp.text

    def test_no_banner_without_params(self, client):
        resp = client.get("/jobs")
        assert 'class="flash' not in resp.text

    def test_banner_escapes_html(self, client):
        resp = client.get("/jobs?flash=error:%3Cscript%3Ealert(1)%3C/script%3E")
        assert "<script>alert(1)</script>" not in resp.text
