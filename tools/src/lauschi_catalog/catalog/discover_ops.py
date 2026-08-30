"""Library functions for artist discovery across providers.

Pure business logic with no console output. Progress is reported via
callbacks so both the CLI (Rich tables) and the web UI (job log) can
consume it.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

from lauschi_catalog.catalog.add_ops import add_series, title_to_id
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.loader import (
    load_catalog,
    load_raw,
    save_raw,
    update_provider_ids,
)
from lauschi_catalog.catalog.paths import artist_image_path
from lauschi_catalog.providers import Artist, CatalogProvider


@dataclass
class DiscoverMatch:
    """A candidate artist match from a provider."""

    provider: str
    artist_id: str
    artist_name: str
    genres: list[str] = field(default_factory=list)
    followers: int = 0
    confidence: str = "weak"
    image_url: str = ""


@dataclass
class DiscoverResult:
    """Result of discovering artist IDs for a single series."""

    query: str
    matches: dict[str, DiscoverMatch | None]
    candidates: dict[str, list[DiscoverMatch]]
    written: bool = False
    created_new: bool = False
    new_series_id: str | None = None


@dataclass
class DiscoverAllResult:
    """Result of discovering missing IDs across the entire catalog."""

    found_total: int
    updates: dict[str, dict[str, list[str]]]
    written: int = 0


@dataclass
class PruneResult:
    """Result of pruning broken artist IDs."""

    checked: int
    broken: int
    pruned_series: dict[str, dict[str, list[str]]]
    written: int = 0


Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


def classify_match(series_title: str, candidate: Artist) -> str:
    """Return confidence label for a candidate match."""
    title_lower = series_title.lower()
    name_lower = candidate.name.lower()

    if name_lower == title_lower:
        return "exact"
    if title_lower in name_lower or name_lower in title_lower:
        return "substring"

    kids_genres = {"kinder", "hörspiel", "hörbuch", "children", "kids", "spoken"}
    genre_str = " ".join(candidate.genres).lower()
    if any(g in genre_str for g in kids_genres):
        return "genre"

    return "weak"


def match_artist(
    series_title: str,
    candidates: list[Artist],
) -> Artist | None:
    """Find the best matching artist for a series title.

    Accepts only exact name match or substring. Genre-only or
    single-candidate heuristics are intentionally rejected: we do not
    want to write a random kids-audio artist to series.yaml just
    because it is the only search result.
    """
    title_lower = series_title.lower()

    for c in candidates:
        if c.name.lower() == title_lower:
            return c

    for c in candidates:
        name_lower = c.name.lower()
        if title_lower in name_lower or name_lower in title_lower:
            return c

    return None


def discover_for_provider(
    provider: CatalogProvider,
    series_title: str,
) -> Artist | None:
    """Search a single provider and return the best matching artist."""
    candidates = provider.search_artists(series_title)
    return match_artist(series_title, candidates)


def discover_candidates(
    provider: CatalogProvider,
    series_title: str,
) -> list[tuple[Artist, str]]:
    """Return all candidates with confidence classification."""
    candidates = provider.search_artists(series_title)
    return [(c, classify_match(series_title, c)) for c in candidates]


def _artist_to_match(artist: Artist, confidence: str) -> DiscoverMatch:
    return DiscoverMatch(
        provider=artist.provider,
        artist_id=artist.id,
        artist_name=artist.name,
        genres=artist.genres,
        followers=artist.followers,
        confidence=confidence,
        image_url=artist.image_url,
    )


def _save_artist_images(
    series_id: str,
    matches: dict[str, DiscoverMatch | None],
    candidates: dict[str, list[DiscoverMatch]],
) -> None:
    """Cache artist image URLs from matched candidates."""
    images: dict[str, str] = {}
    for pname, match in matches.items():
        if match is None:
            continue
        for c in candidates.get(pname, []):
            if c.artist_id == match.artist_id and c.image_url:
                images[pname] = c.image_url
                break
    if images:
        path = artist_image_path(series_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        safe_write_json(path, images)


def discover_one(
    query: str,
    providers: list[CatalogProvider],
    *,
    write: bool = False,
    on_progress: Progress = _noop,
) -> DiscoverResult:
    """Discover artist IDs for a single series across all providers.

    With ``write=True``, persists discovered IDs to series.yaml
    (merging with existing IDs, or creating a new entry if needed).
    """
    matches: dict[str, DiscoverMatch | None] = {}
    all_candidates: dict[str, list[DiscoverMatch]] = {}

    for p in providers:
        candidates = discover_candidates(p, query)
        all_candidates[p.name] = [_artist_to_match(a, conf) for a, conf in candidates]
        best = match_artist(query, [a for a, _ in candidates])
        if best:
            conf = classify_match(query, best)
            matches[p.name] = _artist_to_match(best, conf)
            on_progress(f"  [{p.name}] {best.name} ({best.id})")
        else:
            matches[p.name] = None
            on_progress(f"  [{p.name}] not found")

    result = DiscoverResult(query=query, matches=matches, candidates=all_candidates)

    if not write:
        return result

    discoveries = {name: m for name, m in matches.items() if m is not None}

    catalog = load_catalog()
    entry = None
    for e in catalog:
        if e.id == query or e.title == query:
            entry = e
            break

    series_id = entry.id if entry else title_to_id(query)
    _save_artist_images(series_id, matches, all_candidates)

    if not entry:
        sure: dict[str, DiscoverMatch] = {
            pname: m
            for pname, m in discoveries.items()
            if m.confidence in ("exact", "substring")
        }
        if not sure:
            on_progress(
                "No sure matches; skipped creating series "
                f"'{title_to_id(query)}' (use catalog-add to create it)"
            )
            return result

        artists = {
            pname: Artist(
                id=m.artist_id,
                name=m.artist_name,
                provider=pname,
                genres=m.genres,
                followers=m.followers,
                image_url=m.image_url,
            )
            for pname, m in sure.items()
        }

        add_result = add_series(
            query,
            artists=artists,
            on_progress=on_progress,
        )
        if not add_result.ok:
            on_progress(f"Failed to create series: {add_result.error}")
            return result

        result.written = True
        result.created_new = True
        result.new_series_id = add_result.series_id
        on_progress(
            f"Created new series '{query}' (id: {add_result.series_id}) "
            f"with {len(artists)} provider(s)"
        )
        return result

    raw = load_raw()
    updated = False
    for raw_entry in raw.get("series", []):
        if raw_entry.get("id") != entry.id:
            continue
        raw_providers = raw_entry.setdefault("providers", {})
        for pname, m in discoveries.items():
            # Only exact/substring matches are written automatically.
            if m.confidence not in ("exact", "substring"):
                on_progress(
                    f"  [{pname}] weak match '{m.artist_name}' not written; "
                    "use catalog-edit to add it manually"
                )
                continue
            raw_cfg = raw_providers.setdefault(pname, {})
            existing: list[str] = raw_cfg.get("artist_ids") or []
            if m.artist_id not in existing:
                existing.append(m.artist_id)
                raw_cfg["artist_ids"] = existing
                updated = True
                on_progress(f"Added {pname} artist_id {m.artist_id} to {entry.id}")
        break

    if updated:
        save_raw(raw)
        result.written = True
        on_progress("Updated series.yaml")
    else:
        on_progress("No new artist_ids to write.")

    return result


def discover_all(
    providers: list[CatalogProvider],
    *,
    write: bool = False,
    on_progress: Progress = _noop,
) -> DiscoverAllResult:
    """Discover missing artist IDs for all catalog series."""
    entries = load_catalog()
    updates: dict[str, dict[str, list[str]]] = {}
    found_total = 0

    for entry in entries:
        any_missing = False
        for p in providers:
            existing = entry.artist_ids(p.name)
            if existing:
                continue
            any_missing = True
            best = match_artist(entry.title, p.search_artists(entry.title))
            if best:
                found_total += 1
                updates.setdefault(entry.id, {})[p.name] = [best.id]
                on_progress(f"  {entry.title}: {p.name} -> {best.id}")
            else:
                on_progress(f"  {entry.title}: {p.name} -> not found")

        if not any_missing:
            on_progress(f"  {entry.title}: all providers present")

    result = DiscoverAllResult(found_total=found_total, updates=updates)
    on_progress(f"{found_total} new IDs discovered")

    if write and updates:
        result.written = update_provider_ids(updates=updates)
        on_progress(f"Updated {result.written} entries in series.yaml")

    return result


def prune_broken(
    providers: list[CatalogProvider],
    *,
    write: bool = False,
    on_progress: Progress = _noop,
) -> PruneResult:
    """Remove artist_ids that return 404 from their provider."""
    entries = load_catalog()
    updates: dict[str, dict[str, list[str]]] = {}
    broken_count = 0
    checked_count = 0

    for entry in entries:
        for p in providers:
            existing = entry.artist_ids(p.name)
            if not existing:
                continue
            kept: list[str] = []
            removed: list[str] = []
            for aid in existing:
                checked_count += 1
                try:
                    ok = p.artist_exists(aid)
                except Exception as e:
                    on_progress(f"  error checking {entry.id}/{p.name}/{aid}: {e}")
                    kept.append(aid)
                    continue
                if ok:
                    kept.append(aid)
                else:
                    removed.append(aid)
                    broken_count += 1
            if removed:
                on_progress(
                    f"  {entry.id}/{p.name}: removed {', '.join(removed)}, "
                    f"kept {', '.join(kept) or '(empty)'}"
                )
                updates.setdefault(entry.id, {})[p.name] = kept

    result = PruneResult(
        checked=checked_count,
        broken=broken_count,
        pruned_series=updates,
    )
    on_progress(
        f"Checked {checked_count} artist_ids; "
        f"{broken_count} broken across {len(updates)} series"
    )

    if write and updates:
        result.written = update_provider_ids(updates=updates)
        on_progress(f"Updated {result.written} entries in series.yaml")

    return result
