"""Which reference index series and lines a catalog entry is compared against.

A family (a main series and its sub-series) is compared with the index
series whose name is the main series' title or one of its aliases, case
and outer spaces folded but punctuation kept, so "Die drei ???" and
"Die drei !!!" stay apart. Each line of that series then goes to the
family member whose shipped titles cover most of it, three titles or a
third of the line at least. A member that covers no line is not compared.

Where the names differ, or a line belongs to a member its titles do not
show, ``assets/catalog/reference_map.yaml`` says so per entry::

    overrides:
      bobo_siebenschlaefer: null      # the index has nothing for it
      lillis_abenteuer: 30            # compare with index series 30
      hexe_lilli_musik:               # these lines of series 10 are its own
        series: 10
        lines: [Musik]

An override on a main series holds for its whole family, unless a member
has one of its own.
"""

import difflib
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, TypedDict

from lauschi_catalog.catalog import io
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.partition import Family, families
from lauschi_catalog.catalog.paths import reference_map_path
from lauschi_catalog.reference import ReferenceIndex, ReferenceLine, ReferenceSeries

#: name: by the index series' name. map: by reference_map.yaml.
#: no_line: the family maps, but no line fits this member. unmapped: no
#: index series has the family's name. not_in_index: the override file
#: says the index holds nothing for it.
How = Literal["name", "map", "no_line", "unmapped", "not_in_index"]


class Override(TypedDict, total=False):
    series: int
    lines: list[str]


@dataclass(frozen=True)
class EntryMapping:
    entry_id: str
    series: ReferenceSeries | None
    lines: tuple[ReferenceLine, ...]
    how: How


_STOP = frozenset(
    "der die das und ein eine einer eines den dem des im in am an auf zu zum zur "
    "von vom mit fur für folge teil hörspiel horspiel cd episode special the and of a".split()
)
_UNSET = object()
#: a line belongs to the member that ships this many of its titles, or this share
_MIN_HITS = 3
_MIN_SHARE = 0.3


def story_words(title: str, drop: frozenset[str] = frozenset()) -> frozenset[str]:
    """The words that name a story: no brackets, numbers or filler words."""
    text = unicodedata.normalize("NFC", title).lower()
    text = re.sub(r"\(.*?\)|\[.*?\]", " ", text)
    words = re.findall(r"[a-zäöüß]+", text)
    return frozenset(
        w for w in words if w not in _STOP and w not in drop and len(w) > 1
    )


def _fold(word: str) -> str:
    for plain, umlaut in (("ae", "ä"), ("oe", "ö"), ("ue", "ü"), ("ss", "ß")):
        word = word.replace(umlaut, plain)
    return re.sub(r"(.)\1+", r"\1", word)


def _part(title: str) -> str | None:
    """The part of a two-parter. "Teil 3: ..." at the start is a volume
    number, not a part."""
    m = re.search(r"(?<!^)\b(?:teil|part)\s*(\d+)", title.lower().strip())
    return m.group(1) if m else None


def same_story(a: str, b: str, drop: frozenset[str] = frozenset()) -> bool:
    """Whether two titles name the same story: most words shared, spelling
    variants folded, the parts of a two-parter kept apart. ``drop`` holds
    the brand's own words, which every title of it carries."""
    if _part(a) != _part(b):
        return False
    wa, wb = story_words(a, drop), story_words(b, drop)
    if not wa or not wb:
        # a title that is only the brand plus digits ("5:0 für Benjamin")
        digits_a, digits_b = re.sub(r"\D", "", a), re.sub(r"\D", "", b)
        return bool(digits_a) and digits_a in digits_b
    fa, fb = {_fold(w) for w in wa}, {_fold(w) for w in wb}
    if len(fa & fb) / min(len(fa), len(fb)) >= 0.75:
        return True
    ratio = difflib.SequenceMatcher(
        None, " ".join(sorted(fa)), " ".join(sorted(fb))
    ).ratio()
    return ratio >= 0.85


def brand_words(*names: str) -> frozenset[str]:
    """Words of the brand's names, which say nothing about the story."""
    return frozenset(w for name in names for w in story_words(name))


def load_overrides(path: Path | None = None) -> dict[str, Override | None]:
    """The override file as entry id to override, None meaning the index
    holds nothing for the entry. A missing file has no overrides."""
    target = path if path is not None else reference_map_path()
    if not target.exists():
        return {}
    data = io.yaml_instance().load(target) or {}
    overrides: dict[str, Override | None] = {}
    for entry_id, value in (data.get("overrides") or {}).items():
        if value is None:
            overrides[str(entry_id)] = None
        elif isinstance(value, int):
            overrides[str(entry_id)] = {"series": value}
        else:
            override: Override = {"series": int(value["series"])}
            if value.get("lines"):
                override["lines"] = [str(name) for name in value["lines"]]
            overrides[str(entry_id)] = override
    return overrides


def shipped_titles(entry: CatalogEntry) -> list[str]:
    return [
        a["title"]
        for cfg in entry.providers.values()
        for a in cfg.albums
        if a.get("title")
    ]


def _name_key(name: str) -> str:
    return unicodedata.normalize("NFC", name).strip().casefold()


def _series_by_name(family: Family, index: ReferenceIndex) -> ReferenceSeries | None:
    by_key: dict[str, int] = {}
    for series_id, name in index.names().items():
        by_key.setdefault(_name_key(name), series_id)
    root = family.parent
    assert root is not None, "map_catalog splits a dissolved family into its entries"
    for name in (root.title, *root.aliases):
        series_id = by_key.get(_name_key(name))
        if series_id is not None:
            return index.series(series_id)
    return None


def _hits(line: ReferenceLine, titles: list[str], drop: frozenset[str]) -> int:
    return sum(
        1 for ep in line.episodes if any(same_story(ep.title, t, drop) for t in titles)
    )


def _family_series(
    family: Family,
    index: ReferenceIndex,
    overrides: dict[str, Override | None],
) -> tuple[ReferenceSeries | None, How]:
    if family.root_id in overrides:
        root = overrides[family.root_id]
        if root is None:
            return None, "not_in_index"
        return index.series(root["series"]), "map"
    series = _series_by_name(family, index)
    return (series, "name") if series is not None else (None, "unmapped")


def _map_family(
    family: Family,
    index: ReferenceIndex,
    overrides: dict[str, Override | None],
) -> dict[str, EntryMapping]:
    series, how = _family_series(family, index, overrides)
    out: dict[str, EntryMapping] = {}
    pool: list[CatalogEntry] = []
    for member in family.members:
        own = (
            overrides.get(member.id, _UNSET) if member.id != family.root_id else _UNSET
        )
        if own is _UNSET:
            pool.append(member)
        elif own is None:
            out[member.id] = EntryMapping(member.id, None, (), "not_in_index")
        elif "lines" not in own and series is not None and own["series"] == series.id:
            # the family's own series: its lines go by coverage like the rest
            pool.append(member)
        else:
            theirs = index.series(own["series"])
            wanted = set(own.get("lines") or [line.name for line in theirs.lines])
            lines = tuple(line for line in theirs.lines if line.name in wanted)
            out[member.id] = EntryMapping(member.id, theirs, lines, "map")

    if series is None:
        for member in pool:
            out[member.id] = EntryMapping(member.id, None, (), how)
        return out

    taken = {
        line.name
        for m in out.values()
        if m.series is not None and m.series.id == series.id
        for line in m.lines
    }
    drop = brand_words(series.name, *(m.title for m in family.members))
    titles = {m.id: shipped_titles(m) for m in pool}
    owned: dict[str, list[ReferenceLine]] = {m.id: [] for m in pool}
    for line in series.lines:
        if line.name in taken or not line.episodes or not pool:
            continue
        best = max(pool, key=lambda m: _hits(line, titles[m.id], drop))
        hits = _hits(line, titles[best.id], drop)
        if hits and (hits >= _MIN_HITS or hits >= _MIN_SHARE * len(line.episodes)):
            owned[best.id].append(line)
    for member in pool:
        lines = tuple(owned[member.id])
        out[member.id] = EntryMapping(
            member.id, series, lines, how if lines else "no_line"
        )
    return out


def map_catalog(
    catalog: list[CatalogEntry],
    index: ReferenceIndex,
    overrides: dict[str, Override | None],
) -> dict[str, EntryMapping]:
    """Every entry's index series and lines, family by family."""
    mapping: dict[str, EntryMapping] = {}
    for family in families(catalog).values():
        # The entries of a dissolved main series are brands of their own
        # (Pippi, Michel, Karlsson), each with its own index series.
        own = (
            [family]
            if family.parent is not None
            else [Family(child.id, child, ()) for child in family.children]
        )
        for each in own:
            mapping.update(_map_family(each, index, overrides))
    return mapping
