"""The Preview tab must always render the preview.

The base series route picks a smart default tab (pipeline while work
remains, preview when done). The Preview tab button used to link to
that base route, so for any series whose pipeline wasn't 'done',
clicking Preview jumped straight back to the Pipeline tab. The tab now
links to an explicit /preview route that bypasses the default logic.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog.web.main import app


@pytest.fixture
def client():
    return TestClient(app)


def _pipeline_state(status: str):
    class State:
        pass

    s = State()
    s.status = status
    s.current_step = "apply"
    s.current_label = "Apply"
    s.step_labels = ["Discover", "Curate", "Audit", "Apply", "Validate"]
    s.step_statuses = ["done", "done", "done", "current", "pending"]
    return s


def _get(client, path):
    with patch(
        "lauschi_catalog.web.routes.catalog.pipeline_status",
        return_value=_pipeline_state("in_progress"),
    ), patch(
        "lauschi_catalog.web.routes.catalog.get_active_job",
        return_value=None,
    ):
        return client.get(path)


def _tab_button_line(html: str, label: str) -> str:
    # Tab buttons render as one <a role="button" class="...">Label</a> line;
    # matching on the class attribute skips the global nav links.
    return next(
        line for line in html.splitlines()
        if f">{label}</a>" in line and "class=" in line
    )


def test_explicit_preview_route_renders_preview(client):
    resp = _get(client, "/catalog/5_geschwister/preview")
    assert resp.status_code == 200
    # The active tab carries the 'contrast' class on its button.
    assert "contrast" in _tab_button_line(resp.text, "Preview")


def test_base_route_keeps_smart_default(client):
    resp = _get(client, "/catalog/5_geschwister")
    assert resp.status_code == 200
    assert "contrast" in _tab_button_line(resp.text, "Pipeline")


def test_preview_tab_links_to_explicit_route(client):
    resp = _get(client, "/catalog/5_geschwister")
    assert 'href="/catalog/5_geschwister/preview"' in resp.text
