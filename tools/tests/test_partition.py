"""Tests for the split-family partition model."""

import json

from lauschi_catalog.catalog.partition import (
    families,
    family_ids_from_curation_dir,
    family_of,
)
from tests.factories import entry


def test_standalone_entry():
    cat = [entry("tkkg")]
    fam = family_of(cat[0], cat)
    assert fam.root_id == "tkkg"
    assert fam.parent.id == "tkkg"
    assert fam.children == ()
    assert fam.is_standalone
    assert fam.members == (cat[0],)


def test_family_from_parent():
    parent = entry("ninjago")
    child1 = entry("ninjago_hoerbuch", split_from="ninjago")
    child2 = entry("ninjago_film", split_from="ninjago")
    cat = [parent, child1, child2]

    fam = family_of(parent, cat)
    assert fam.root_id == "ninjago"
    assert fam.parent is parent
    assert set(c.id for c in fam.children) == {"ninjago_hoerbuch", "ninjago_film"}
    assert not fam.is_standalone
    assert fam.is_child("ninjago_hoerbuch")
    assert not fam.is_child("ninjago")


def test_family_from_child():
    parent = entry("ninjago")
    child = entry("ninjago_hoerbuch", split_from="ninjago")
    cat = [parent, child]

    fam = family_of(child, cat)
    assert fam.root_id == "ninjago"
    assert fam.parent is parent
    assert fam.children == (child,)


def test_siblings_of():
    parent = entry("ninjago")
    child1 = entry("ninjago_hoerbuch", split_from="ninjago")
    child2 = entry("ninjago_film", split_from="ninjago")
    cat = [parent, child1, child2]

    fam = family_of(parent, cat)
    siblings = fam.siblings_of("ninjago_hoerbuch")
    ids = {s.id for s in siblings}
    assert ids == {"ninjago", "ninjago_film"}


def test_children_of_parent():
    parent = entry("ninjago")
    child = entry("ninjago_hoerbuch", split_from="ninjago")
    cat = [parent, child]

    fam = family_of(parent, cat)
    assert fam.children_of("ninjago") == (child,)
    assert fam.children_of("ninjago_hoerbuch") == ()


def test_families_builds_all():
    p1 = entry("tkkg")
    p2 = entry("ninjago")
    c2 = entry("ninjago_hoerbuch", split_from="ninjago")
    cat = [p1, p2, c2]

    fams = families(cat)
    assert set(fams.keys()) == {"tkkg", "ninjago"}
    assert fams["tkkg"].is_standalone
    assert not fams["ninjago"].is_standalone
    assert fams["ninjago"].children == (c2,)


def test_family_ids_from_curation_dir(tmp_path):
    parent = {"id": "ninjago", "albums": []}
    child = {"id": "ninjago_hoerbuch", "split_from": "ninjago", "albums": []}
    other = {"id": "tkkg", "albums": []}

    (tmp_path / "ninjago.json").write_text(json.dumps(parent))
    (tmp_path / "ninjago_hoerbuch.json").write_text(json.dumps(child))
    (tmp_path / "tkkg.json").write_text(json.dumps(other))

    parent_id, child_ids = family_ids_from_curation_dir("ninjago", tmp_path)
    assert parent_id is None  # ninjago has no split_from
    assert child_ids == ["ninjago_hoerbuch"]


def test_family_ids_from_child_perspective(tmp_path):
    parent = {"id": "ninjago", "albums": []}
    child = {"id": "ninjago_hoerbuch", "split_from": "ninjago", "albums": []}

    (tmp_path / "ninjago.json").write_text(json.dumps(parent))
    (tmp_path / "ninjago_hoerbuch.json").write_text(json.dumps(child))

    parent_id, child_ids = family_ids_from_curation_dir("ninjago_hoerbuch", tmp_path)
    assert parent_id == "ninjago"
    assert child_ids == []


def test_family_ids_missing_file(tmp_path):
    parent_id, child_ids = family_ids_from_curation_dir("nonexistent", tmp_path)
    assert parent_id is None
    assert child_ids == []
