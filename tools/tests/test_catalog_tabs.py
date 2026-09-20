"""Catalog list tabs count and filter all content types, including audiobook."""

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.main import app
from tests.factories import entry


@pytest.fixture
def client():
    return TestClient(app)


def _mock_series():
    return [
        entry("tkkg", content_type="hoerspiel"),
        entry("bibi", content_type="hoerspiel"),
        entry("sing_kinderlieder", content_type="music"),
        entry("liliane_susewind", content_type="audiobook"),
        entry("der_kleine_siebenschlaefer", content_type="audiobook"),
    ]


def test_audiobook_tab_shows_audiobook_count(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.get_all_series",
        return_value=_mock_series(),
    ):
        resp = client.get("/catalog?tab=audiobook")

    assert resp.status_code == 200
    html = resp.text
    assert "Hörbücher" in html
    assert "liliane_susewind" in html
    assert "der_kleine_siebenschlaefer" in html
    assert "tkkg" not in html


def test_all_tab_includes_audiobooks_in_total(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.get_all_series",
        return_value=_mock_series(),
    ):
        resp = client.get("/catalog?tab=all")

    assert resp.status_code == 200
    html = resp.text
    assert "liliane_susewind" in html
    assert "tkkg" in html


def test_tab_counts_include_audiobooks(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.get_all_series",
        return_value=_mock_series(),
    ):
        resp = client.get("/catalog?tab=hoerspiel")

    assert resp.status_code == 200
    html = resp.text
    # The audiobook count badge should show 2
    assert ">2<" in html.replace(" ", "")


def test_tab_links_do_not_carry_status_filter(client):
    with patch(
        "lauschi_catalog.web.routes.catalog.get_all_series",
        return_value=_mock_series(),
    ):
        resp = client.get("/catalog?tab=hoerspiel&status=Validate")

    html = resp.text
    assert "tab=audiobook&amp;status=" not in html
    assert "tab=audiobook" in html
