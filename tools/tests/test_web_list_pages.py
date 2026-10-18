"""The pages that list every series read the run-event log once.

`pipeline_status` reads the validate step from the log. Called once per
series it re-read every run file for each of them, about 240 reads of
7,000 events per render, and /catalog took 13 to 22 seconds on a
checkout with a pipeline history (2026-10-19).
"""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from lauschi_catalog import run_events
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.run_events import OUTCOME_OK, RunEvent, record_event
from lauschi_catalog.web.routes import catalog as catalog_routes
from tests.conftest import ScratchCatalog

ENTRIES = [
    CatalogEntry(
        id=f"s{i}",
        title=f"S{i}",
        providers={
            "spotify": ProviderConfig(
                artist_ids=["a"], album_ids=["x"], has_albums=True
            )
        },
    )
    for i in range(3)
]


@pytest.fixture
def reads(
    scratch_catalog: ScratchCatalog, monkeypatch: pytest.MonkeyPatch
) -> list[Path | None]:
    for entry in ENTRIES:
        scratch_catalog.write_curation(
            {
                "id": entry.id,
                "curated_at": "2026-07-01T00:00:00+00:00",
                "review": {
                    "audited_at": "2026-07-02T00:00:00+00:00",
                    "status": "approved",
                },
                "albums": [],
            }
        )
    record_event(RunEvent(series_id="s1", phase="validate", outcome=OUTCOME_OK))
    monkeypatch.setattr(catalog_routes, "get_all_series", lambda: list(ENTRIES))

    calls: list[Path | None] = []
    read_events = run_events.read_events

    def counting_read(base: Path | None = None) -> list[RunEvent]:
        calls.append(base)
        return read_events(base)

    monkeypatch.setattr(run_events, "read_events", counting_read)
    return calls


@pytest.mark.parametrize("page", ["/catalog", "/pipeline", "/review"])
def test_a_list_page_reads_the_event_log_once(
    web_client: TestClient, reads: list[Path | None], page: str
) -> None:
    assert web_client.get(page).status_code == 200
    assert len(reads) == 1
