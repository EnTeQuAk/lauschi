"""Library functions for catalog validation.

L1  SYNTAX      required fields, regex compiles, unique IDs
L5  ARTIST      full discography via artist ID (per provider)

Pure business logic with no console output.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime

import requests

from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.matcher import extract_episode
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.providers import Album, CatalogProvider

Progress = Callable[[str], None]
_noop: Progress = lambda _msg: None


@dataclass
class L5ProviderResult:
    """L5 validation result for a single series/provider pair."""

    provider: str
    matched: int = 0
    total: int = 0
    unmatched: list[str] = field(default_factory=list)

    @property
    def rate(self) -> float:
        return self.matched / self.total if self.total > 0 else 0.0

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
            patterns = [e.episode_pattern] if isinstance(e.episode_pattern, str) else e.episode_pattern
            for p in patterns:
                try:
                    re.compile(p)
                except re.error as err:
                    issues.append(f"{e.id}: bad pattern {p!r}: {err}")
    return issues


def validate_l5(
    entry: CatalogEntry,
    provider: CatalogProvider,
) -> L5ProviderResult:
    """L5: full discography validation via artist ID."""
    aids = entry.artist_ids(provider.name)
    if not aids:
        return L5ProviderResult(provider=provider.name)

    all_albums: list[Album] = []
    for aid in aids:
        try:
            all_albums.extend(provider.artist_albums(aid))
        except requests.HTTPError as e:
            status = e.response.status_code if e.response is not None else None
            if status == 404:
                continue
            raise

    if not all_albums:
        return L5ProviderResult(provider=provider.name)

    pattern = entry.effective_pattern(provider.name)
    matched = 0
    unmatched: list[str] = []

    for album in all_albums:
        ep = extract_episode(pattern, album.name)
        if ep is not None:
            matched += 1
        else:
            unmatched.append(album.name)

    return L5ProviderResult(
        provider=provider.name,
        matched=matched,
        total=len(all_albums),
        unmatched=unmatched,
    )


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
    if series_filter:
        q = series_filter.lower()
        entries = [e for e in entries if q in e.title.lower() or q in e.id]

    l1_issues = validate_l1(entries)
    if l1_issues:
        for issue in l1_issues:
            on_progress(f"L1 SYNTAX: {issue}")
    else:
        on_progress(f"L1 SYNTAX: {len(entries)} series, no issues")

    result = ValidationResult(l1_issues=l1_issues)

    if not providers:
        return result

    result.perfect = {p.name: 0 for p in providers}
    result.tested = {p.name: 0 for p in providers}

    for entry in entries:
        has_any = any(entry.artist_ids(p.name) for p in providers)
        if not has_any:
            continue

        sv = SeriesValidation(
            series_id=entry.id,
            title=entry.title,
            pattern=entry.episode_pattern,
        )

        for p in providers:
            aids = entry.artist_ids(p.name)
            if not aids:
                continue

            l5 = validate_l5(entry, p)
            sv.l5_results[p.name] = l5
            result.tested[p.name] += 1

            if l5.is_perfect:
                result.perfect[p.name] += 1

            if l5.total > 0:
                on_progress(
                    f"  {entry.title}/{p.name}: {l5.matched}/{l5.total}"
                )

        result.series_results.append(sv)

        if stamp_curations:
            curation_path = CURATION_DIR / f"{entry.id}.json"
            if curation_path.exists():
                try:
                    data = json.loads(curation_path.read_text())
                    data["validated_at"] = datetime.now(UTC).isoformat()
                    curation_path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
                except Exception:
                    pass

    for p in providers:
        if result.tested[p.name] > 0:
            on_progress(
                f"{p.name}: {result.perfect[p.name]}/{result.tested[p.name]} "
                f"series with perfect match rate"
            )

    return result
