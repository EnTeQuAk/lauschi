"""Split-off children are pre-excluded from the parent deterministically.

A fresh curation of a parent (Kira Kolumna) with a split child (Kira
Kolumna Reportage) must exclude all the child's albums as
sub_series_bleed before the batch phase decides anything. The albums
are sourced from series.yaml (the applied, authoritative record),
which is present even when the child has no curation file in the
working directory. That absence is exactly what let two clean runs
split the 28 Reportage items 21/7 differently (2026-09-05).
"""

import json

import pytest

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig


def _parent() -> CatalogEntry:
    return CatalogEntry(id="kira_kolumna", title="Kira Kolumna")


def _child_with_yaml_albums() -> CatalogEntry:
    return CatalogEntry(
        id="kira_kolumna_reportage",
        title="Kira Kolumna Reportage",
        split_from="kira_kolumna",
        providers={
            "spotify": ProviderConfig(
                artist_ids=["art"],
                album_ids=["sp1", "sp2"],
                albums=[
                    {"id": "sp1", "title": "Reportage: One"},
                    {"id": "sp2", "title": "Reportage: Two"},
                ],
            ),
            "apple_music": ProviderConfig(
                album_ids=["am1"],
                albums=[{"id": "am1", "title": "Reportage: One"}],
            ),
        },
    )


def test_child_albums_are_injected_from_series_yaml_without_a_curation_file(
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setattr(
        curate_ops, "load_catalog", lambda: [_parent(), _child_with_yaml_albums()]
    )
    result = curate_ops._inject_split_children(None, "kira_kolumna")
    injected = {(a["provider"], a["album_id"]): a for a in result["albums"]}
    assert set(injected) == {
        ("spotify", "sp1"),
        ("spotify", "sp2"),
        ("apple_music", "am1"),
    }
    for a in injected.values():
        assert a["include"] is False
        assert a["exclude_reason"] == "sub_series_bleed"
        assert a["title"]  # real title, not a placeholder


def test_injection_does_not_duplicate_an_already_present_album(
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setattr(
        curate_ops, "load_catalog", lambda: [_parent(), _child_with_yaml_albums()]
    )
    existing = {
        "albums": [
            {"provider": "spotify", "album_id": "sp1", "include": True, "title": "kept"}
        ]
    }
    result = curate_ops._inject_split_children(existing, "kira_kolumna")
    sp1 = [a for a in result["albums"] if a["album_id"] == "sp1"]
    assert len(sp1) == 1
    assert sp1[0]["include"] is True  # the existing decision is not overwritten


def test_no_children_leaves_the_curation_untouched(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(curate_ops, "load_catalog", lambda: [_parent()])
    assert curate_ops._inject_split_children(None, "kira_kolumna") is None


def test_the_curation_fallback_counts_only_the_childs_included_albums(
    monkeypatch, tmp_path
):
    """A curated but unapplied child's file holds the whole shared page,
    most of it excluded. Only what the child includes is the child's:
    the parent run would otherwise pre-exclude its entire page as bleed
    (Wieso? Weshalb? Warum? Vorlesegeschichten, 2026-09-06: 367 records,
    3 included)."""
    from lauschi_catalog.catalog import curate_ops
    from lauschi_catalog.catalog.curate_ops import _child_album_records
    from lauschi_catalog.catalog.models import CatalogEntry

    child = CatalogEntry(id="kid", title="Kid", split_from="parent")
    (tmp_path / "kid.json").write_text(
        json.dumps(
            {
                "albums": [
                    {
                        "provider": "spotify",
                        "album_id": "own",
                        "title": "Mine",
                        "include": True,
                    },
                    {
                        "provider": "spotify",
                        "album_id": "p1",
                        "title": "Parent's",
                        "include": False,
                        "exclude_reason": "sub_series_bleed",
                    },
                ]
            }
        )
    )
    monkeypatch.setattr(
        curate_ops, "curation_path", lambda sid: tmp_path / f"{sid}.json"
    )
    assert _child_album_records(child) == [("spotify", "own", "Mine")]
