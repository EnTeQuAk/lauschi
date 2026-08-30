"""pipeline_status must tolerate a curation whose review block is an
explicit null.

A missing "review" key and a stored ``"review": null`` are different
JSON, and twelve real curation files carry the null. The web dashboard
renders every series' pipeline state on /catalog, so one null review
crashed the whole page:

    AttributeError: 'NoneType' object has no attribute 'get'
    src/lauschi_catalog/web/pipeline.py:92
"""

import json

from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig
from lauschi_catalog.web import pipeline as pipeline_mod


def _entry() -> CatalogEntry:
    return CatalogEntry(
        id="s", title="S", providers={"spotify": ProviderConfig(artist_ids=["a"])}
    )


def _stage(tmp_path, monkeypatch, curation: dict) -> None:
    path = tmp_path / "s.json"
    path.write_text(json.dumps(curation))
    monkeypatch.setattr(pipeline_mod, "curation_path", lambda _sid: path)


def test_null_review_reads_as_not_audited(tmp_path, monkeypatch):
    _stage(
        tmp_path,
        monkeypatch,
        {"curated_at": "2026-07-01T00:00:00+00:00", "review": None},
    )
    state = pipeline_mod.pipeline_status("s", series=_entry())
    # curated but never audited: the audit step is the current one
    assert state.step_statuses[1] == "done"
    assert state.step_statuses[2] == "current"


def test_missing_review_key_reads_the_same_as_null(tmp_path, monkeypatch):
    _stage(tmp_path, monkeypatch, {"curated_at": "2026-07-01T00:00:00+00:00"})
    absent = pipeline_mod.pipeline_status("s", series=_entry())
    _stage(
        tmp_path,
        monkeypatch,
        {"curated_at": "2026-07-01T00:00:00+00:00", "review": None},
    )
    null = pipeline_mod.pipeline_status("s", series=_entry())
    assert absent.step_statuses == null.step_statuses


def test_validate_step_reads_the_run_event_log(tmp_path, monkeypatch):
    """The validate step is done when the last validate event for this
    series was ok, not when an in-file timestamp is present."""
    _stage(
        tmp_path,
        monkeypatch,
        {
            "curated_at": "2026-07-01T00:00:00+00:00",
            "albums": [],
            "review": {
                "audited_at": "2026-07-02T00:00:00+00:00",
                "status": "approved",
            },
        },
    )
    entry = CatalogEntry(
        id="s",
        title="S",
        providers={
            "spotify": ProviderConfig(
                artist_ids=["a"], album_ids=["x"], has_albums=True
            )
        },
    )
    outcomes: dict[tuple[str, str], str | None] = {}

    monkeypatch.setattr(
        pipeline_mod,
        "latest_outcome_for",
        lambda sid, phase: outcomes.get((sid, phase)),
    )

    state = pipeline_mod.pipeline_status("s", series=entry)
    assert state.step_statuses[4] == "current"  # applied, never validated

    outcomes[("s", "validate")] = "ok"
    state = pipeline_mod.pipeline_status("s", series=entry)
    assert state.step_statuses[4] == "done"

    # Another series' validate event does not validate this one.
    outcomes.clear()
    outcomes[("other", "validate")] = "ok"
    state = pipeline_mod.pipeline_status("s", series=entry)
    assert state.step_statuses[4] == "current"
