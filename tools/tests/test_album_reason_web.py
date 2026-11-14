"""The web UI takes only curate reasons for an excluded album.

A re-curation reads every prior record into the curate model, and a
reason outside that vocabulary aborts the run, so the album table offers
the curate reasons and the API refuses any other.
"""

from typing import TYPE_CHECKING, Any
from unittest.mock import patch

import pytest

from lauschi_catalog.catalog.reasons import CURATE_REASON_KEYS
from lauschi_catalog.web.catalog_store import get_all_series, reload_catalog
from tests.conftest import ScratchCatalog

if TYPE_CHECKING:
    from fastapi.testclient import TestClient

_ALBUM: dict[str, Any] = {
    "album_id": "alb1",
    "provider": "spotify",
    "include": True,
    "title": "Folge 1",
}


@pytest.fixture
def curation(scratch_catalog: ScratchCatalog) -> ScratchCatalog:
    scratch_catalog.write_curation({"id": "test_series", "albums": [dict(_ALBUM)]})
    return scratch_catalog


def test_a_curate_reason_is_saved(
    curation: ScratchCatalog, web_client: "TestClient"
) -> None:
    resp = web_client.patch(
        "/api/series/test_series/albums/alb1",
        json={"include": False, "exclude_reason": "not_kids_content"},
    )

    assert resp.status_code == 200, resp.text
    album = curation.read_curation("test_series")["albums"][0]
    assert album["include"] is False
    assert album["exclude_reason"] == "not_kids_content"


def test_a_reason_the_next_curate_cannot_read_is_refused(
    curation: ScratchCatalog, web_client: "TestClient"
) -> None:
    resp = web_client.patch(
        "/api/series/test_series/albums/alb1",
        json={"include": False, "exclude_reason": "adult album"},
    )

    assert resp.status_code == 422
    assert "not_kids_content" in resp.text
    assert curation.read_curation("test_series")["albums"] == [_ALBUM]


def test_the_album_table_offers_the_curate_reasons(web_client: "TestClient") -> None:
    # The store is filled at app startup, which a bare TestClient skips.
    if not get_all_series():
        reload_catalog()
    with patch(
        "lauschi_catalog.web.routes.catalog.get_active_job",
        return_value=None,
    ):
        resp = web_client.get("/catalog/5_geschwister/episodes")

    assert resp.status_code == 200
    for key in CURATE_REASON_KEYS:
        assert f'<option value="{key}">{key}</option>' in resp.text
    assert 'placeholder="Reason…"' not in resp.text
