"""Library functions for adding series to the catalog.

Pure business logic for title-to-ID conversion, episode pattern
analysis, and series entry construction. Interactive prompts and
provider search stay in the CLI layer.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass

from lauschi_catalog.catalog.deleted import is_deleted, remove_from_deleted
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.series_ops import add_series_entry
from lauschi_catalog.providers import Album, Artist

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


_PATTERNS: list[tuple[str, str]] = [
    ("NNN/", r"^(\d{1,3})/"),
    ("N:", r"^(\d{1,2}):\s"),
    ("Folge N", r"[Ff]olge\s+(\d+)"),
    ("Teil N", r"[Tt]eil\s+(\d+)"),
    ("Episode N", r"[Ee]pisode\s+(\d+)"),
    ("Fall N", r"[Ff]all\s+(\d+)"),
    ("Band N", r"[Bb]and\s+(\d+)"),
    ("Hörspiel N", r"[Hh]örspiel\s+(\d+)"),
    ("Nr. N", r"[Nn]r\\.?\\s+(\\d+)"),
]


def title_to_id(title: str) -> str:
    """Convert a series title to a snake_case ASCII identifier.

    Replaces brand-name punctuation (???, !!!, &) with German words,
    then handles umlauts (ae, oe, ue, ss) before stripping the rest.
    """
    s = title
    s = s.replace("???", " Fragezeichen ")
    s = s.replace("!!!", " Ausrufezeichen ")
    s = s.replace("&", " und ")
    s = s.lower()
    for src, dst in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")]:
        s = s.replace(src, dst)
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_")


def which_pattern(title: str) -> tuple[str, str] | None:
    """Return the (name, regex) of the first matching pattern, or None."""
    for name, pat in _PATTERNS:
        if re.search(pat, title):
            return name, pat
    return None


def analyse_patterns(albums: list[Album]) -> dict:
    """Analyze album titles for episode numbering patterns.

    Returns a dict with pattern distribution, dominant pattern regex,
    and gap analysis.
    """
    titles = [a.name for a in albums]

    pattern_of: dict[str, tuple[str, str]] = {}
    for t in titles:
        match = which_pattern(t)
        if match:
            pattern_of[t] = match

    by_pattern: Counter[str] = Counter(name for name, _ in pattern_of.values())

    dominant_name = by_pattern.most_common(1)[0][0] if by_pattern else None
    dominant_regex: str | None = None
    if dominant_name:
        for name, pat in _PATTERNS:
            if name == dominant_name:
                dominant_regex = pat
                break

    numbered: list[tuple[str, int]] = []
    if dominant_regex:
        for t in titles:
            m = re.search(dominant_regex, t)
            if m:
                try:
                    numbered.append((t, int(m.group(1))))
                except (ValueError, IndexError):
                    pass
    numbered.sort(key=lambda x: x[1])

    nums = [n for _, n in numbered]
    if nums:
        full_range = set(range(min(nums), max(nums) + 1))
        gaps = sorted(full_range - set(nums))
    else:
        gaps = []

    return {
        "total": len(titles),
        "by_pattern": dict(by_pattern.most_common()),
        "unmatched": [t for t in titles if t not in pattern_of],
        "numbered": numbered,
        "gaps": gaps,
        "dominant_name": dominant_name,
        "dominant_regex": dominant_regex,
    }


def build_entry(
    title: str,
    *,
    series_id: str | None = None,
    artists: dict[str, Artist] | None = None,
    analysis: dict | None = None,
) -> dict:
    """Build a series.yaml entry dict.

    Args:
        title: Series title.
        series_id: Override for the auto-generated ID.
        artists: {provider_name: Artist} from discovery.
        analysis: Pattern analysis from analyse_patterns(), if available.
    """
    sid = series_id or title_to_id(title)

    entry: dict[str, str | dict | list[str]] = {
        "id": sid,
        "title": title,
    }

    if analysis and analysis.get("dominant_regex"):
        entry["episode_pattern"] = analysis["dominant_regex"]

    if artists:
        providers: dict[str, dict[str, list[str]]] = {}
        for pname, artist in sorted(artists.items()):
            providers[pname] = {"artist_ids": [artist.id]}
        entry["providers"] = providers

    return entry


@dataclass
class AddResult:
    """Result of adding a series."""

    ok: bool = True
    series_id: str = ""
    error: str | None = None


def add_series(
    title: str,
    *,
    series_id: str | None = None,
    artists: dict[str, Artist] | None = None,
    analysis: dict | None = None,
    force_readd: bool = False,
    on_progress: Progress = _noop,
) -> AddResult:
    """Add a new series to the catalog (non-interactive).

    Checks for duplicates and deleted entries, builds the entry,
    and writes to series.yaml.
    """
    sid = series_id or title_to_id(title)

    existing = load_catalog()
    existing_ids = {e.id for e in existing}
    if sid in existing_ids:
        return AddResult(
            ok=False, series_id=sid, error=f"series '{sid}' already exists"
        )

    deletion = is_deleted(sid)
    if deletion and not force_readd:
        reason = deletion.get("reason", "(no reason recorded)")
        return AddResult(
            ok=False,
            series_id=sid,
            error=f"series '{sid}' was previously deleted. Reason: {reason}",
        )

    entry = build_entry(
        title,
        series_id=series_id,
        artists=artists,
        analysis=analysis,
    )

    result = add_series_entry(entry)
    if not result.ok:
        return AddResult(ok=False, series_id=sid, error=result.error)

    if force_readd and deletion:
        remove_from_deleted(sid)
        on_progress(f"Removed {sid!r} from deleted.yaml.")

    on_progress(f"Added '{sid}' to series.yaml")
    return AddResult(ok=True, series_id=sid)
