"""Which reference index series and lines a catalog entry is compared against.

A family (a main series and its sub-series) is compared with the index
series named like its main series: by the exact name or an alias first,
so "Die drei ???" and "Die drei !!!" stay apart, then by the name without
punctuation, then by an index name the main series' name starts with
("Dragons - Die Reiter von Berk" is the index's Dragons). A sub-series of
a family the index does not know (an author's) tries its own name.

Every entry compared with one index series shares its lines, whether the
entries are one family or several main series. Each line goes to the
entry whose shipped titles cover most of it, three titles or a third of
the line at least. A line no entry covers goes to the main series that
found the index series by its name, so the QA still checks it. An entry
left with no line is not compared.

Where the names differ, or a line belongs to a member its titles do not
show, ``assets/catalog/reference_map.json`` says so per entry: null when
the index has nothing for it, an index series id to compare it with, or
that series with the lines that are the entry's own::

    {
      "overrides": {
        "bobo_siebenschlaefer": null,
        "lillis_abenteuer": 30,
        "hexe_lilli_musik": {"series": 10, "lines": ["Musik"]}
      }
    }

An override on a main series holds for its whole family, unless a member
has one of its own.
"""

import difflib
import functools
import json
import re
import unicodedata
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Literal, TypedDict

from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.partition import Family, families
from lauschi_catalog.catalog.paths import reference_map_path
from lauschi_catalog.reference import ReferenceIndex, ReferenceLine, ReferenceSeries

#: name: by the index series' name. prefix: the entry's name starts with
#: it. map: by reference_map.json.
#: no_line: the family maps, but no line fits this member. unmapped: no
#: index series has the family's name. not_in_index: the override file
#: says the index holds nothing for it.
How = Literal["name", "prefix", "map", "no_line", "unmapped", "not_in_index"]


class Override(TypedDict, total=False):
    series: int
    lines: list[str]


@dataclass(frozen=True)
class EntryMapping:
    entry_id: str
    series: ReferenceSeries | None
    lines: tuple[ReferenceLine, ...]
    how: How
    #: lines among ``lines`` that no entry ships, given to this main series
    leftover: tuple[ReferenceLine, ...] = ()


_STOP = frozenset(
    "der die das und ein eine einer eines den dem des im in am an auf zu zum zur "
    "von vom mit fur für folge teil hörspiel horspiel cd episode special the and of a".split()
)
_UNSET = object()
#: a line belongs to the member that ships this many of its titles, or this share
_MIN_HITS = 3
_MIN_SHARE = 0.3


@functools.cache
def story_words(title: str, drop: frozenset[str] = frozenset()) -> frozenset[str]:
    """The words that name a story: no brackets, numbers or filler words."""
    text = unicodedata.normalize("NFC", title).lower()
    text = re.sub(r"\(.*?\)|\[.*?\]", " ", text)
    words = re.findall(r"[a-zäöüß]+", text)
    return frozenset(
        w for w in words if w not in _STOP and w not in drop and len(w) > 1
    )


def fold_word(word: str) -> str:
    """A word with umlauts spelled out and doubled letters single."""
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
    variants folded, the parts of a two-parter kept apart. A title without
    a part matches either part, since one album often holds both. ``drop``
    holds the brand's own words, which every title of it carries."""
    part_a, part_b = _part(a), _part(b)
    if part_a and part_b and part_a != part_b:
        return False
    wa, wb = story_words(a, drop), story_words(b, drop)
    if not wa or not wb:
        # a title that is only the brand plus digits ("5:0 für Benjamin")
        digits_a, digits_b = re.sub(r"\D", "", a), re.sub(r"\D", "", b)
        return bool(digits_a) and digits_a in digits_b
    fa, fb = {fold_word(w) for w in wa}, {fold_word(w) for w in wb}
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
    data = json.loads(target.read_text(encoding="utf-8")) or {}
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


def _loose_key(name: str) -> str:
    """A name without its punctuation, so "Käpt'n Sharky" meets "Käpt’n
    Sharky" and "H2O - Plötzlich Meerjungfrau!" meets "H2O – Plötzlich
    Meerjungfrau"."""
    return " ".join(re.findall(r"\w+", unicodedata.normalize("NFKC", name).casefold()))


@dataclass(frozen=True)
class _Names:
    """The index's series names, by exact and by loose key."""

    exact: dict[str, list[int]]
    loose: dict[str, list[int]]

    @classmethod
    def of(cls, index: ReferenceIndex) -> "_Names":
        exact: dict[str, list[int]] = {}
        loose: dict[str, list[int]] = {}
        for series_id, name in index.names().items():
            exact.setdefault(_name_key(name), []).append(series_id)
            loose.setdefault(_loose_key(name), []).append(series_id)
        return cls(exact, loose)


def _coverage(series: ReferenceSeries, titles: list[str], name: str) -> int:
    drop = brand_words(series.name, name)
    return sum(_hits(line, titles, drop) for line in series.lines)


def _series_named(
    names: tuple[str, ...],
    titles: list[str],
    index: ReferenceIndex,
    lookup: _Names,
) -> tuple[ReferenceSeries, How] | None:
    """The index series an entry's names point to. The exact name comes
    first, so "Die drei ???" and "Die drei !!!" stay apart, then the name
    without punctuation, then an index name the entry's name starts with
    ("Dragons - Die Reiter von Berk" is the index's Dragons). That last
    one counts only when the series holds one of the entry's titles. The
    index holds some names twice (Unser Sandmännchen, LEGO Ninjago), and
    then the series that covers most of the albums wins."""

    def best(ids: list[int]) -> ReferenceSeries:
        candidates = [index.series(i) for i in ids]
        if len(candidates) == 1:
            return candidates[0]
        return max(candidates, key=lambda s: _coverage(s, titles, names[0]))

    for key_of, table in ((_name_key, lookup.exact), (_loose_key, lookup.loose)):
        for name in names:
            if ids := table.get(key_of(name)):
                return best(ids), "name"
    longest = ""
    for name in names:
        loose = _loose_key(name)
        for key in lookup.loose:
            if len(key) > len(longest) and loose.startswith(key + " "):
                longest = key
    if longest:
        series = best(lookup.loose[longest])
        if _coverage(series, titles, names[0]):
            return series, "prefix"
    return None


@dataclass
class _Unit:
    """Entries compared with one index series: a family, or a sub-series
    that found an index series by its own name."""

    root: CatalogEntry | None
    series: ReferenceSeries | None
    how: How
    pool: list[CatalogEntry]


def _hits(line: ReferenceLine, titles: list[str], drop: frozenset[str]) -> int:
    return sum(
        1 for ep in line.episodes if any(same_story(ep.title, t, drop) for t in titles)
    )


def _units(
    family: Family,
    index: ReferenceIndex,
    lookup: _Names,
    overrides: dict[str, Override | None],
    out: dict[str, EntryMapping],
) -> list[_Unit]:
    """The family's units. Members with an override of their own are
    mapped into ``out`` right away."""
    root = family.parent
    assert root is not None, "map_catalog splits a dissolved family into its entries"
    series: ReferenceSeries | None
    how: How
    if family.root_id in overrides:
        given = overrides[family.root_id]
        series, how = (
            (None, "not_in_index")
            if given is None
            else (index.series(given["series"]), "map")
        )
    else:
        found = _series_named(
            (root.title, *root.aliases),
            [t for m in family.members for t in shipped_titles(m)],
            index,
            lookup,
        )
        series, how = found if found is not None else (None, "unmapped")

    pool: list[CatalogEntry] = []
    for member in family.members:
        own = overrides.get(member.id, _UNSET)
        if member.id == family.root_id and not (
            isinstance(own, dict) and "lines" in own
        ):
            # the main series' own override names the family's series
            own = _UNSET
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

    units = [_Unit(root if root in pool else None, series, how, pool)]
    if series is None and how == "unmapped":
        # An author's family (Michael Ende) is not in the index, but its
        # sub-series (Jim Knopf) may be, under their own names.
        for member in [m for m in pool if m is not root]:
            found = _series_named(
                (member.title, *member.aliases), shipped_titles(member), index, lookup
            )
            if found is not None:
                pool.remove(member)
                units.append(_Unit(member, found[0], found[1], [member]))
    return units


def _share_lines(group: list[_Unit], out: dict[str, EntryMapping]) -> None:
    """Hand out the lines of the series these units are compared with.
    Each line goes to the entry that ships most of it, three titles or a
    third of the line at least. A line nobody ships goes to the main
    series of the best fitting unit, so the QA still sees it."""
    series = group[0].series
    assert series is not None
    taken = {
        line.name
        for m in out.values()
        if m.series is not None and m.series.id == series.id
        for line in m.lines
    }
    pool = [m for unit in group for m in unit.pool]
    drop = brand_words(series.name, *(m.title for m in pool))
    titles = {m.id: shipped_titles(m) for m in pool}
    owned: dict[str, list[ReferenceLine]] = {m.id: [] for m in pool}
    unowned: list[ReferenceLine] = []
    for line in series.lines:
        if line.name in taken or not line.episodes:
            continue
        best = max(pool, key=lambda m: _hits(line, titles[m.id], drop), default=None)
        hits = _hits(line, titles[best.id], drop) if best is not None else 0
        if (
            best is not None
            and hits
            and (hits >= _MIN_HITS or hits >= _MIN_SHARE * len(line.episodes))
        ):
            owned[best.id].append(line)
        else:
            unowned.append(line)

    homes = [u for u in group if u.root is not None]
    named = [u for u in homes if u.how != "prefix"] or homes
    home = max(
        named,
        key=lambda u: sum(len(owned[m.id]) for m in u.pool),
        default=None,
    )
    for unit in group:
        for member in unit.pool:
            lines = owned[member.id]
            leftover: tuple[ReferenceLine, ...] = ()
            if home is not None and member is home.root and unowned:
                lines = lines + unowned
                leftover = tuple(unowned)
            out[member.id] = EntryMapping(
                member.id,
                series,
                tuple(lines),
                unit.how if lines else "no_line",
                leftover,
            )


def map_catalog(
    catalog: list[CatalogEntry],
    index: ReferenceIndex,
    overrides: dict[str, Override | None],
) -> dict[str, EntryMapping]:
    """Every entry's index series and lines. Entries compared with one
    index series share its lines, whether they are one family or not."""
    lookup = _Names.of(index)
    out: dict[str, EntryMapping] = {}
    units: list[_Unit] = []
    for family in families(catalog).values():
        # The entries of a dissolved main series are brands of their own
        # (Pippi, Michel, Karlsson), each with its own index series.
        own = (
            [family]
            if family.parent is not None
            else [Family(child.id, child, ()) for child in family.children]
        )
        for each in own:
            units.extend(_units(each, index, lookup, overrides, out))
    by_series: dict[int, list[_Unit]] = {}
    for unit in units:
        if unit.series is None:
            for member in unit.pool:
                out[member.id] = EntryMapping(member.id, None, (), unit.how)
        elif unit.pool:
            by_series.setdefault(unit.series.id, []).append(unit)
    for group in by_series.values():
        _share_lines(group, out)
    return out


#: "Die Piraten - Teil 2" as a track is a piece of the story, not its second part
_TRACK_PART = re.compile(r"\s*[-–]\s*(teil|part|kapitel|track)\s*\d+.*$", re.IGNORECASE)
#: the index lags behind the stores by weeks, so a newer album is set aside
_INDEX_LAG = timedelta(weeks=8)


def barcode_key(code: str) -> str:
    """A barcode as it compares: a 12-digit UPC is the 13-digit EAN with a
    leading zero, and stores and the index write either."""
    return code.strip().lstrip("0")


@dataclass(frozen=True)
class IndexEpisode:
    line: str
    number: int | None
    title: str
    #: the barcode of the release the episode is part of, as `barcode_key`
    barcode: str = ""


@dataclass(frozen=True)
class ShippedAlbum:
    """One release as the entry ships it, the stores' twins taken as one."""

    number: int | None
    title: str
    providers: tuple[str, ...]
    release_date: str | None
    #: (provider, album id) of each store's release
    ids: tuple[tuple[str, str], ...] = ()
    #: each store's barcode for it, as `barcode_key`
    barcodes: frozenset[str] = frozenset()


@dataclass(frozen=True)
class Pair:
    index: IndexEpisode
    ours: ShippedAlbum


@dataclass
class EntryMatch:
    """What a deterministic comparison of an entry with its index lines
    settles, and the two lists it leaves open."""

    matched: int = 0
    #: index stories bundled into an album that matched another story
    bundled: int = 0
    #: index stories found among the track names of a shipped album
    in_tracks: int = 0
    number_differs: list[Pair] = field(default_factory=list)
    #: the same number on both sides, a different story
    title_differs: list[Pair] = field(default_factory=list)
    #: matched, and we ship it without the number the index gives
    unnumbered: list[Pair] = field(default_factory=list)
    open_index: list[IndexEpisode] = field(default_factory=list)
    open_ours: list[ShippedAlbum] = field(default_factory=list)
    #: numbered above the index lines or released lately: the index cannot know them yet
    newer: list[ShippedAlbum] = field(default_factory=list)


def _number(value: str | None) -> int | None:
    return int(value) if value is not None and value.isdigit() else None


def shipped_albums(entry: CatalogEntry) -> list[ShippedAlbum]:
    """The entry's albums, one per episode number or, unnumbered, per title."""
    merged: dict[object, dict] = {}
    for provider, cfg in entry.providers.items():
        for album in cfg.albums:
            number = album.get("episode")
            title = album.get("title") or ""
            key = number if number is not None else _name_key(title)
            row = merged.setdefault(
                key,
                {
                    "number": number,
                    "title": title,
                    "providers": [],
                    "ids": [],
                    "barcodes": set(),
                    "release_date": album.get("release_date"),
                },
            )
            row["providers"].append(provider)
            row["ids"].append((provider, album["id"]))
            if album.get("barcode"):
                row["barcodes"].add(barcode_key(album["barcode"]))
    return [
        ShippedAlbum(
            r["number"],
            r["title"],
            tuple(r["providers"]),
            r["release_date"],
            tuple(r["ids"]),
            frozenset(r["barcodes"]),
        )
        for r in merged.values()
    ]


def match_entry(
    entry: CatalogEntry,
    lines: tuple[ReferenceLine, ...],
    *,
    today: date,
    drop: frozenset[str] = frozenset(),
    tracks: Callable[[], list[str]] | None = None,
    barcodes: Mapping[int, str] | None = None,
) -> EntryMatch:
    """Pair the entry's shipped albums with the episodes of its index lines.

    A story pairs with the album that carries its release's barcode first
    (``barcodes`` holds them by the index's product id), whatever the two
    titles say, and the other stories of that release count as bundled.
    Then a story pairs under its own number, then by title anywhere. An
    index story that pairs with nothing may sit in an album that matched
    another story, or among the track names, which ``tracks`` reads only
    when it gets that far.
    """
    ours = shipped_albums(entry)
    result = EntryMatch()
    used: set[int] = set()
    track_titles: list[str] | None = None
    codes = barcodes or {}
    episodes = [
        IndexEpisode(
            line.name,
            _number(ep.number),
            ep.title,
            barcode_key(codes[ep.product]) if ep.product in codes else "",
        )
        for line in lines
        for ep in line.episodes
    ]
    by_number = {a.number: i for i, a in enumerate(ours) if a.number is not None}
    by_barcode = {code: i for i, a in enumerate(ours) for code in a.barcodes}

    unpaired: list[IndexEpisode] = []
    for ep in episodes:
        i = by_barcode.get(ep.barcode) if ep.barcode else None
        if i is None:
            unpaired.append(ep)
        elif i in used:
            result.bundled += 1
        else:
            used.add(i)
            album = ours[i]
            if (
                ep.number is not None
                and album.number is not None
                and ep.number != album.number
            ):
                result.number_differs.append(Pair(ep, album))
                continue
            result.matched += 1
            if ep.number is not None and album.number is None:
                result.unnumbered.append(Pair(ep, album))

    pending: list[IndexEpisode] = []
    for ep in unpaired:
        i = by_number.get(ep.number) if ep.number is not None else None
        if (
            i is not None
            and i not in used
            and same_story(ep.title, ours[i].title, drop)
        ):
            used.add(i)
            result.matched += 1
        else:
            pending.append(ep)

    for ep in pending:
        i = next(
            (
                j
                for j, a in enumerate(ours)
                if j not in used and same_story(ep.title, a.title, drop)
            ),
            None,
        )
        if i is not None:
            used.add(i)
            album = ours[i]
            if (
                ep.number is not None
                and album.number is not None
                and ep.number != album.number
            ):
                result.number_differs.append(Pair(ep, album))
                continue
            result.matched += 1
            if ep.number is not None and album.number is None:
                result.unnumbered.append(Pair(ep, album))
            continue
        if any(same_story(ep.title, ours[j].title, drop) for j in used):
            result.bundled += 1
            continue
        i = by_number.get(ep.number) if ep.number is not None else None
        if i is not None and i not in used:
            used.add(i)
            result.title_differs.append(Pair(ep, ours[i]))
            continue
        if tracks is not None:
            if track_titles is None:
                track_titles = [_TRACK_PART.sub("", t) for t in tracks()]
            if any(same_story(ep.title, t, drop) for t in track_titles):
                result.in_tracks += 1
                continue
        result.open_index.append(ep)

    top = max((ep.number or 0 for ep in episodes), default=0)
    for j, album in enumerate(ours):
        if j in used:
            continue
        recent = bool(album.release_date) and str(album.release_date) > str(
            today - _INDEX_LAG
        )
        if recent or (album.number is not None and album.number > top):
            result.newer.append(album)
        else:
            result.open_ours.append(album)
    return result
