"""Library functions for catalog validation.

L1  SYNTAX      required fields, regex compiles, unique IDs
L5  ARTIST      full discography via artist ID (per provider)

Pure business logic with no console output.
"""

import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime

import requests

from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.matcher import extract_episode
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.providers import Album, CatalogProvider
from lauschi_catalog.run_events import OUTCOME_OK, RunEvent, record_event

Progress = Callable[[str], None]

#: ``\\d`` and friends: a literal backslash followed by a class letter.
#: Compiles, never matches.
_DOUBLE_ESCAPED = re.compile(r"\\\\[dDwWsShHbB]")


def _noop(_msg: str) -> None:
    pass


@dataclass
class L5ProviderResult:
    """L5 validation result for a single series/provider pair."""

    provider: str
    matched: int = 0
    total: int = 0
    unmatched: list[str] = field(default_factory=list)
    album_check: bool = False
    unverified: list[str] = field(default_factory=list)
    pattern_matched: int = 0
    pattern_total: int = 0
    pattern_unmatched: list[str] = field(default_factory=list)
    has_pattern: bool = False

    @property
    def rate(self) -> float:
        return self.matched / self.total if self.total > 0 else 0.0

    @property
    def pattern_rate(self) -> float:
        return (
            self.pattern_matched / self.pattern_total if self.pattern_total > 0 else 0.0
        )

    @property
    def is_perfect(self) -> bool:
        return self.total > 0 and self.matched == self.total


@dataclass
class SeriesValidation:
    """Validation result for a single series."""

    series_id: str
    title: str
    pattern: str | list[str] | None = None
    l5_results: dict[str, L5ProviderResult] = field(default_factory=dict)


@dataclass
class ValidationResult:
    """Full catalog validation result."""

    l1_issues: list[str] = field(default_factory=list)
    series_results: list[SeriesValidation] = field(default_factory=list)
    perfect: dict[str, int] = field(default_factory=dict)
    tested: dict[str, int] = field(default_factory=dict)


def validate_l1(entries: list[CatalogEntry]) -> list[str]:
    """L1: syntax checks."""
    issues: list[str] = []
    ids_seen: set[str] = set()
    for e in entries:
        if not e.id:
            issues.append(f"Entry missing id: {e.title}")
        if e.id in ids_seen:
            issues.append(f"Duplicate id: {e.id}")
        ids_seen.add(e.id)
        if e.episode_pattern:
            patterns = (
                [e.episode_pattern]
                if isinstance(e.episode_pattern, str)
                else e.episode_pattern
            )
            for p in patterns:
                try:
                    re.compile(p)
                except re.error as err:
                    issues.append(f"{e.id}: bad pattern {p!r}: {err}")
                # A double-escaped shortcut compiles fine but matches a
                # literal backslash, so it silently never fires. This is
                # what single-quoted YAML does to '\\d' and it went
                # unnoticed for months because the extractor repaired it
                # in passing instead of rejecting it.
                if _DOUBLE_ESCAPED.search(p):
                    issues.append(
                        f"{e.id}: double-escaped shortcut in pattern {p!r} "
                        f"— matches a literal backslash, never an episode "
                        f"number (single-quoted YAML does not process "
                        f"escapes; use one backslash)"
                    )

    # Cross-series album uniqueness. The app indexes albums by
    # provider:albumId and lets the last series in file order win
    # (CatalogService._buildAlbumIndex), so a duplicated album is
    # attributed arbitrarily and appears under two tiles in browse.
    owners: dict[tuple[str, str], list[str]] = {}
    for e in entries:
        for provider, cfg in e.providers.items():
            for album_id in cfg.album_ids:
                owners.setdefault((provider, album_id), []).append(e.id)
    for (provider, album_id), series_ids in sorted(owners.items()):
        if len(series_ids) > 1:
            issues.append(
                f"Album {provider}:{album_id} ships in "
                f"{len(series_ids)} series: {', '.join(sorted(series_ids))}"
            )
    return issues


def validate_l5(
    entry: CatalogEntry,
    provider: CatalogProvider,
) -> L5ProviderResult:
    """L5: full discography validation via artist ID + configured album existence."""
    aids = entry.artist_ids(provider.name)
    pattern = entry.effective_pattern(provider.name)
    configured_ids = entry.provider_album_ids(provider.name)

    result = L5ProviderResult(provider=provider.name)

    # Always check configured album IDs for existence, even when a pattern
    # exists. `albums_by_ids` is batched and distinguishes "not found"
    # from "could not verify" (unverified).
    if configured_ids:
        result.album_check = True
        result.total = len(configured_ids)
        batch = provider.albums_by_ids(configured_ids)
        found_ids = {a.id for a in batch.albums}
        result.matched = sum(1 for cid in configured_ids if cid in found_ids)
        result.unmatched = [
            cid
            for cid in configured_ids
            if cid not in found_ids and cid not in batch.unverified
        ]
        result.unverified = list(batch.unverified)

    # Pattern match rate over the artist discography, kept as a second metric.
    if pattern and aids:
        result.has_pattern = True
        all_albums: list[Album] = []
        for aid in aids:
            try:
                all_albums.extend(provider.artist_albums(aid))
            except requests.HTTPError as e:
                status = e.response.status_code if e.response is not None else None
                if status == 404:
                    continue
                raise

        if all_albums:
            result.pattern_total = len(all_albums)
            result.pattern_matched = sum(
                1 for a in all_albums if extract_episode(pattern, a.name) is not None
            )
            result.pattern_unmatched = [
                a.name for a in all_albums if extract_episode(pattern, a.name) is None
            ]

    return result


def validate_catalog(
    providers: list[CatalogProvider],
    *,
    series_filter: str | None = None,
    stamp_curations: bool = True,
    on_progress: Progress = _noop,
) -> ValidationResult:
    """Validate catalog syntax and discography match rates.

    When ``stamp_curations`` is True (default), writes a
    ``validated_at`` timestamp into each series' curation JSON.
    """
    entries = load_catalog()
    l1_entries = entries

    l1_issues = validate_l1(l1_entries)
    if l1_issues:
        for issue in l1_issues:
            on_progress(f"L1 SYNTAX: {issue}")
    else:
        on_progress(f"L1 SYNTAX: {len(l1_entries)} series, no issues")

    result = ValidationResult(l1_issues=l1_issues)

    if not providers:
        return result

    result.perfect = {p.name: 0 for p in providers}
    result.tested = {p.name: 0 for p in providers}

    if series_filter:
        q = series_filter.lower()
        l5_entries = [e for e in entries if q in e.title.lower() or q in e.id]
    else:
        l5_entries = entries

    for entry in l5_entries:
        has_any = any(
            entry.artist_ids(p.name) or entry.provider_album_ids(p.name)
            for p in providers
        )
        if not has_any:
            continue

        sv = SeriesValidation(
            series_id=entry.id,
            title=entry.title,
            pattern=entry.episode_pattern,
        )

        for p in providers:
            if not entry.artist_ids(p.name) and not entry.provider_album_ids(p.name):
                continue

            l5 = validate_l5(entry, p)
            sv.l5_results[p.name] = l5
            result.tested[p.name] += 1

            if l5.is_perfect:
                result.perfect[p.name] += 1

            if l5.total > 0:
                prefix = "ids:" if l5.album_check else ""
                on_progress(
                    f"  {entry.title}/{p.name}: {prefix}{l5.matched}/{l5.total}"
                )

        result.series_results.append(sv)

        if stamp_curations:
            curation_path = CURATION_DIR / f"{entry.id}.json"
            if curation_path.exists():
                try:
                    data = json.loads(curation_path.read_text())
                    data["validated_at"] = datetime.now(UTC).isoformat()
                    safe_write_json(curation_path, data)
                except Exception:
                    pass
                record_event(
                    RunEvent(
                        series_id=entry.id,
                        phase="validate",
                        outcome=OUTCOME_OK,
                        detail=", ".join(
                            f"{p.name}: {sv.l5_results[p.name].matched}/"
                            f"{sv.l5_results[p.name].total}"
                            for p in providers
                            if p.name in sv.l5_results
                        ),
                    )
                )

    for p in providers:
        if result.tested[p.name] > 0:
            on_progress(
                f"{p.name}: {result.perfect[p.name]}/{result.tested[p.name]} "
                f"series with perfect match rate"
            )

    return result
