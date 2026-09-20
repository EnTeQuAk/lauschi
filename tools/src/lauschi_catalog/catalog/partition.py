"""Canonical partition model for split series families.

A split family is a parent series plus its split-off children, who
share the same artist pages. Seven sites derived this relationship
inline; this module is the single source of truth.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from lauschi_catalog.catalog.models import CatalogEntry


@dataclass(frozen=True)
class Family:
    """A split family: one parent and zero or more children."""

    parent: CatalogEntry
    children: tuple[CatalogEntry, ...]

    @property
    def root_id(self) -> str:
        return self.parent.id

    @property
    def members(self) -> tuple[CatalogEntry, ...]:
        return (self.parent, *self.children)

    def siblings_of(self, entry_id: str) -> tuple[CatalogEntry, ...]:
        """All family members except the named one."""
        return tuple(m for m in self.members if m.id != entry_id)

    def children_of(self, entry_id: str) -> tuple[CatalogEntry, ...]:
        """Children of the named entry (empty if it is itself a child)."""
        if entry_id != self.parent.id:
            return ()
        return self.children

    def is_child(self, entry_id: str) -> bool:
        return any(c.id == entry_id for c in self.children)

    @property
    def is_standalone(self) -> bool:
        return len(self.children) == 0


def family_of(entry: CatalogEntry, catalog: list[CatalogEntry]) -> Family:
    """Build the Family for any entry (parent or child)."""
    root_id = entry.split_from or entry.id
    parent = None
    children: list[CatalogEntry] = []
    for e in catalog:
        if e.id == root_id:
            parent = e
        elif e.split_from == root_id:
            children.append(e)
    if parent is None:
        parent = entry
        children = [e for e in catalog if e.split_from == entry.id]
    return Family(parent=parent, children=tuple(children))


def families(catalog: list[CatalogEntry]) -> dict[str, Family]:
    """All families keyed by root_id."""
    by_root: dict[str, tuple[CatalogEntry | None, list[CatalogEntry]]] = {}
    for e in catalog:
        root = e.split_from or e.id
        if root not in by_root:
            by_root[root] = (None, [])
        parent, kids = by_root[root]
        if e.id == root:
            by_root[root] = (e, kids)
        elif e.split_from == root:
            kids.append(e)
    result: dict[str, Family] = {}
    for root_id, (parent, kids) in by_root.items():
        if parent is None:
            continue
        result[root_id] = Family(parent=parent, children=tuple(kids))
    return result


def family_ids_from_curation_dir(
    series_id: str,
    curation_dir: Path,
) -> tuple[str | None, list[str]]:
    """(parent_id, child_ids) from curation JSON files.

    For eval/truth.py which works from JSON files, not the catalog.
    """
    own_path = curation_dir / f"{series_id}.json"
    if not own_path.is_file():
        return None, []
    own = json.loads(own_path.read_text(encoding="utf-8"))
    parent_id = own.get("split_from")

    child_ids: list[str] = []
    for path in curation_dir.glob("*.json"):
        if path.stem == series_id:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError, OSError:
            continue
        if data.get("split_from") == series_id:
            child_ids.append(data.get("id", path.stem))
    return parent_id, child_ids
