"""Canonical partition model for split series families.

A split family is a parent series plus its split-off children, who
share the same artist pages. Seven sites derived this relationship
inline; this module is the single source of truth.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from lauschi_catalog.catalog.models import CatalogEntry


@dataclass(frozen=True)
class Family:
    """A split family: one root and zero or more children.

    ``parent`` is None when the root entry was dissolved (deleted.yaml)
    and its children kept their ``split_from``: they still share the
    artist page and own each other's albums.
    """

    root_id: str
    parent: CatalogEntry | None
    children: tuple[CatalogEntry, ...]

    @property
    def members(self) -> tuple[CatalogEntry, ...]:
        if self.parent is None:
            return self.children
        return (self.parent, *self.children)

    def siblings_of(self, entry_id: str) -> tuple[CatalogEntry, ...]:
        """All family members except the named one."""
        return tuple(m for m in self.members if m.id != entry_id)

    def children_of(self, entry_id: str) -> tuple[CatalogEntry, ...]:
        """Children of the named entry (empty if it is itself a child)."""
        if entry_id != self.root_id:
            return ()
        return self.children

    def is_child(self, entry_id: str) -> bool:
        return any(c.id == entry_id for c in self.children)

    @property
    def is_standalone(self) -> bool:
        return len(self.children) == 0


_OWNER_NOTE = re.compile(
    r"(?:Belongs to (?:split series )?|Matches the episode pattern of )'([^']+)'"
    r"|^'([^']+)' excluded it as"
)


def bleed_owner(notes: str | None) -> str | None:
    """The family member a bleed record already belongs to, read from the
    note the injection and routing steps leave on it. None for bleed the
    model decided on its own, which is what a split proposal is for."""
    m = _OWNER_NOTE.search(notes or "")
    return (m.group(1) or m.group(2)) if m else None


def family_of(entry: CatalogEntry, catalog: list[CatalogEntry]) -> Family:
    """Build the Family for any entry (parent or child)."""
    root_id = entry.split_from or entry.id
    parent = next((e for e in catalog if e.id == root_id), None)
    children = tuple(e for e in catalog if e.split_from == root_id)
    return Family(root_id=root_id, parent=parent, children=children)


def families(catalog: list[CatalogEntry]) -> dict[str, Family]:
    """All families keyed by root_id, dissolved roots included."""
    roots = dict.fromkeys(e.split_from or e.id for e in catalog)
    return {
        root_id: family_of(
            next(e for e in catalog if (e.split_from or e.id) == root_id), catalog
        )
        for root_id in roots
    }


def catalog_album_owners(
    catalog: list[CatalogEntry], entry_id: str
) -> dict[tuple[str, str], str]:
    """Which other series ships each album, keyed by (provider, album_id).

    Shipping an album is a catalog fact, so it decides ownership on a
    shared artist page whether or not the series are one family. Albums
    the entry ships itself, and albums two other series both ship, have
    no single other owner and are left out.
    """
    own: set[tuple[str, str]] = set()
    shippers: dict[tuple[str, str], set[str]] = {}
    for e in catalog:
        for provider, cfg in e.providers.items():
            for album in cfg.albums:
                key = (provider, album["id"])
                if e.id == entry_id:
                    own.add(key)
                else:
                    shippers.setdefault(key, set()).add(e.id)
    return {
        key: next(iter(ids))
        for key, ids in shippers.items()
        if len(ids) == 1 and key not in own
    }


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
