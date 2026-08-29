"""pipeline_status must tolerate a curation whose review block is an
explicit null.

A missing "review" key and a stored ``"review": null`` are different
JSON, and twelve real curation files carry the null. The web dashboard
renders every series' pipeline state on /catalog, so one null review
crashed the whole page:

    AttributeError: 'NoneType' object has no attribute 'get'
    src/lauschi_catalog/web/pipeline.py:92
"""

from __future__ import annotations

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
