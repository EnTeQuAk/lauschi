"""Flash messages: query-param based, rendered once in base.html.

Routes redirect with ?message= (success) or ?error= via
flash.redirect_with_flash; a template context processor exposes them
to every page as flash_message / flash_error, and base.html renders
the banner. No sessions involved: the message lives in the URL of the
page it lands on.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.flash import redirect_with_flash
from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


class TestRedirectHelper:
    def test_encodes_error(self):
        resp = redirect_with_flash("/catalog", error="delete failed: not found")
        assert resp.status_code == 303
        assert resp.headers["location"] == "/catalog?error=delete+failed%3A+not+found"

    def test_encodes_message(self):
        resp = redirect_with_flash("/jobs", message="job queued")
        assert resp.headers["location"] == "/jobs?message=job+queued"

    def test_plain_redirect_without_params(self):
        resp = redirect_with_flash("/catalog")
        assert resp.headers["location"] == "/catalog"

    def test_appends_to_existing_query(self):
        resp = redirect_with_flash("/catalog?tab=music", error="nope")
        assert resp.headers["location"] == "/catalog?tab=music&error=nope"


class TestBannerRendering:
    def test_error_banner_renders_on_any_page(self, client):
        resp = client.get("/jobs?error=already+running")
        assert resp.status_code == 200
        assert 'class="flash flash-error"' in resp.text
        assert "already running" in resp.text

    def test_message_banner_renders_on_any_page(self, client):
        resp = client.get("/jobs?message=job+queued")
        assert 'class="flash flash-message"' in resp.text
        assert "job queued" in resp.text

    def test_no_banner_without_params(self, client):
        resp = client.get("/jobs")
        assert 'class="flash' not in resp.text

    def test_banner_escapes_html(self, client):
        resp = client.get("/jobs?error=%3Cscript%3Ealert(1)%3C/script%3E")
        assert "<script>alert(1)</script>" not in resp.text
