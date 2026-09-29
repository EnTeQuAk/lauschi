"""The series page shows the split family, dissolved roots included."""

from unittest.mock import patch

from fastapi.testclient import TestClient

from lauschi_catalog.web.main import app
from tests.test_series_detail_tabs import _pipeline_state


def test_child_of_a_dissolved_root_lists_its_siblings() -> None:
    with (
        patch(
            "lauschi_catalog.web.routes.catalog.pipeline_status",
            return_value=_pipeline_state("in_progress"),
        ),
        patch("lauschi_catalog.web.routes.catalog.get_active_job", return_value=None),
        TestClient(app) as client,
    ):
        html = client.get("/catalog/madita").text

    assert "astrid_lindgren_deutsch (dissolved)" in html
    assert 'href="/catalog/astrid_lindgren_deutsch"' not in html
    assert 'href="/catalog/michel_aus_loenneberga"' in html
