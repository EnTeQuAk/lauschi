"""Drift detection: does the catalog still mean what it says?

`series.yaml` is a cached projection of provider state. Existing checks
verify that our data is internally consistent (L1) and that album IDs
resolve (L5), but never that an ID still points at the content we
recorded against it.

That gap shipped a real bug: four Apple Music records in Bibi Blocksberg
drifted onto neighbouring albums, so a kid tapping "Folge 59" heard
Folge 61. The IDs all resolved, so nothing flagged it.

Drift classes this module detects, per album:

  gone      the ID no longer resolves
  critical  the ID resolves to different content
  warning   probably the same content, but something moved
  info      cosmetic metadata touch-up, safe to adopt

The hard part is separating `critical` from `info`. We store only title
and release date per album, so the decisive signal is the episode
number: an ID whose live title yields a different episode number than
the one we recorded has moved to another episode. For content without
episode numbers (films, music, bonus items) we fall back to normalised
title similarity, corroborated by the release year.

Pure classification lives here so it can be tested without the network;
the batched fetching is in `detect_drift`.
"""

import json
import re
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from datetime import date
from difflib import SequenceMatcher
from enum import Enum

from lauschi_catalog.catalog.matcher import extract_episode
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import curation_path
from lauschi_catalog.fanout import map_providers
from lauschi_catalog.providers import Album, CatalogProvider

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


class DriftSeverity(Enum):
    """Ordered worst-first so reports sort naturally."""

    gone = "gone"
    critical = "critical"
    warning = "warning"
    info = "info"
    #: The ID does not resolve yet because the album is not out yet.
    pending = "pending"


#: Normalised-title similarity below this counts as different content.
#: Calibrated against the live catalog rather than guessed.
SIMILARITY_FLOOR = 0.72

#: Below this, a shared episode number stops being evidence of sameness.
#: Publisher renames that keep the episode number sit at 0.57 and above
#: (long qualifiers such as "(Das Original-Hörspiel zur TV-Serie)", typo
#: fixes); genuinely unrelated titles that merely happen to share a
#: number sit far below.
UNRELATED_CEILING = 0.40

#: Store-format decorations providers append and remove freely.
_FORMAT_SUFFIXES = (" - single", " - ep")

_UMLAUTS = str.maketrans(
    {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss", "é": "e", "è": "e", "á": "a"}
)


def normalize_title(title: str) -> str:
    """Fold the differences providers introduce without changing content.

    Case, umlauts, punctuation and whitespace are folded, and the
    ` - Single` / ` - EP` store suffixes are stripped. Parentheticals are
    deliberately kept: "(Remastered 2024)" marks a different edition we
    exclude on purpose, so collapsing it into the original would hide
    real drift.
    """
    text = title.strip().lower().translate(_UMLAUTS)
    for suffix in _FORMAT_SUFFIXES:
        if text.endswith(suffix):
            text = text[: -len(suffix)]
            break
    text = re.sub(r"[^\w\s()\[\]]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def title_similarity(a: str, b: str) -> float:
    """Similarity of two titles after normalisation, 0.0 to 1.0."""
    return SequenceMatcher(None, normalize_title(a), normalize_title(b)).ratio()


def _year(release_date: str | None) -> int | None:
    if not release_date:
        return None
    match = re.match(r"(\d{4})", release_date.strip())
    return int(match.group(1)) if match else None


@dataclass
class DriftFinding:
    """One album whose live state disagrees with what we recorded."""

    album_id: str
    provider: str
    severity: DriftSeverity
    detail: str
    stored_title: str
    live_title: str | None = None
    series_id: str = ""
    stored_episode: int | None = None
    live_episode: int | None = None

    @property
    def is_cosmetic(self) -> bool:
        """Safe to adopt the live title without human review."""
        return self.severity is DriftSeverity.info


def _is_future_release(release_date: str | None, today: date | None) -> bool:
    """True for a full ISO date after today. A bare year is ambiguous
    and never counts as future."""
    if not release_date or len(release_date) < 10:
        return False
    try:
        release = date.fromisoformat(release_date[:10])
    except ValueError:
        return False
    return release > (today or date.today())


def classify_album_drift(
    *,
    album_id: str,
    provider: str,
    stored_title: str,
    stored_episode: int | None,
    stored_release: str | None,
    live_title: str | None,
    live_release: str | None,
    pattern: str | list[str] | None,
    series_id: str = "",
    similarity_floor: float = SIMILARITY_FLOOR,
    today: date | None = None,
) -> DriftFinding | None:
    """Compare one stored album record against its live counterpart.

    Returns None when they agree. A `live_title` of None means the ID does
    not resolve: gone, unless the stored release date is still in the
    future, in which case the album is pending and expected to appear.
    """

    def finding(severity: DriftSeverity, detail: str, live_ep: int | None = None):
        return DriftFinding(
            album_id=album_id,
            provider=provider,
            severity=severity,
            detail=detail,
            stored_title=stored_title,
            live_title=live_title,
            series_id=series_id,
            stored_episode=stored_episode,
            live_episode=live_ep,
        )

    if live_title is None:
        if _is_future_release(stored_release, today):
            return finding(
                DriftSeverity.pending,
                f"not released until {stored_release}; the album ID does not "
                f"resolve on the provider yet",
            )
        return finding(
            DriftSeverity.gone,
            "album ID no longer resolves on the provider",
        )

    live_episode = extract_episode(pattern, live_title)
    titles_equal = normalize_title(stored_title) == normalize_title(live_title)

    # Decisive: the ID now carries a different episode of the same series.
    if (
        stored_episode is not None
        and live_episode is not None
        and stored_episode != live_episode
    ):
        return finding(
            DriftSeverity.critical,
            f"episode number moved: recorded {stored_episode}, "
            f"live title says {live_episode}",
            live_episode,
        )

    stored_year, live_year = _year(stored_release), _year(live_release)
    year_moved = (
        stored_year is not None and live_year is not None and stored_year != live_year
    )

    if titles_equal:
        if year_moved:
            return finding(
                DriftSeverity.warning,
                f"release year moved: recorded {stored_year}, live {live_year}",
                live_episode,
            )
        if stored_title.strip() != live_title.strip():
            # Same content, different spelling on the store: reported so
            # `--fix-titles` can adopt the provider's wording.
            return finding(
                DriftSeverity.info,
                "cosmetic title change (punctuation or store suffix)",
                live_episode,
            )
        return None

    similarity = title_similarity(stored_title, live_title)

    # Same episode number, reworded subtitle: surface it, don't alarm.
    # Unless nothing else matches at all, in which case the shared number
    # is coincidence rather than evidence.
    if (
        stored_episode is not None
        and live_episode is not None
        and stored_episode == live_episode
        and similarity >= UNRELATED_CEILING
    ):
        return finding(
            DriftSeverity.warning,
            f"title changed within episode {stored_episode} "
            f"(similarity {similarity:.2f})",
            live_episode,
        )

    if similarity < similarity_floor:
        severity = (
            DriftSeverity.critical
            if year_moved or stored_episode is None or similarity < UNRELATED_CEILING
            else DriftSeverity.warning
        )
        return finding(
            severity,
            f"title no longer matches (similarity {similarity:.2f})"
            + (f", release year {stored_year} -> {live_year}" if year_moved else ""),
            live_episode,
        )

    # Only decoration or punctuation changed.
    return finding(
        DriftSeverity.info,
        f"cosmetic title change (similarity {similarity:.2f})",
        live_episode,
    )


@dataclass
class DriftResult:
    """Outcome of a drift sweep."""

    findings: list[DriftFinding] = field(default_factory=list)
    checked: dict[str, int] = field(default_factory=dict)
    unresolved_series: list[str] = field(default_factory=list)
    #: yaml-vs-curation set differences, named per series/provider.
    #: Offline (no network), so it also runs before the sweep.
    divergence: list[str] = field(default_factory=list)
    #: IDs whose lookup failed. Absence from the response proves nothing
    #: for these, so they are never reported as gone.
    unverified: list[str] = field(default_factory=list)

    def by_severity(self, severity: DriftSeverity) -> list[DriftFinding]:
        return [f for f in self.findings if f.severity is severity]

    @property
    def counts(self) -> dict[str, int]:
        return {
            s.value: len(self.by_severity(s))
            for s in DriftSeverity
            if self.by_severity(s)
        }


def configured_vs_curation(entry: CatalogEntry, provider: str) -> list[str]:
    """Offline comparison of what series.yaml ships vs what the curation
    includes for one provider.

    Names both directions of the divergence: yaml albums the curation
    never included, and curation includes yaml never configured. The
    online sweep can only check what the curation holds, so a yaml
    album that never made it into the curation is invisible to it;
    this check is the only place that gap surfaces.

    No network. Returns human-readable messages (empty when in sync).
    """
    configured = entry.provider_album_ids(provider)
    if not configured:
        return []
    configured_set = set(configured)

    records = stored_album_records(entry.id, provider, included_only=True)
    included = {str(r.get("album_id") or "") for r in records}

    if not records:
        return [
            f"{entry.id}/{provider}: {len(configured)} album(s) configured in "
            f"series.yaml but the curation has no records for this provider: "
            f"{', '.join(configured)}"
        ]

    messages: list[str] = []
    missing = [aid for aid in configured if aid not in included]
    extra = sorted(included - configured_set)
    if missing:
        messages.append(
            f"{entry.id}/{provider}: {len(missing)} configured album(s) are "
            f"not included in the curation: {', '.join(missing)}"
        )
    if extra:
        messages.append(
            f"{entry.id}/{provider}: {len(extra)} included curation album(s) "
            f"are not configured in series.yaml: {', '.join(extra)}"
        )
    return messages


def stored_album_records(
    series_id: str,
    provider: str,
    *,
    included_only: bool = True,
) -> list[dict]:
    """Album records for a series/provider, read from its curation file.

    The curation is the source rather than series.yaml because it carries
    the release date and the include flag, and because it is what a
    `--fix-titles` repair writes back to.
    """
    path = curation_path(series_id)
    if not path.exists():
        return []
    # Deliberately unguarded: a corrupt or unreadable curation must fail the
    # sweep loudly. Swallowing it would report "no drift" for a series we
    # never actually compared, and a verification tool that hides its own
    # blind spots is worse than none.
    data = json.loads(path.read_text())
    records = [a for a in data.get("albums", []) if a.get("provider") == provider]
    if included_only:
        records = [r for r in records if r.get("include")]
    return records


def detect_drift(
    entries: Sequence[CatalogEntry],
    providers: Iterable[CatalogProvider],
    *,
    included_only: bool = True,
    on_progress: Progress = _noop,
) -> DriftResult:
    """Compare every stored album against its live provider record.

    Fetches in batches (20 per call on Spotify, 100 on Apple Music) and
    always bypasses the disk cache: verifying our snapshot against our
    own cached copy of it would prove nothing. The two providers are
    swept concurrently (independent HTTP clients); findings are merged
    and sorted so the output is identical to the sequential sweep.
    """

    def sweep(provider) -> DriftResult:
        provider_result = DriftResult()

        # Keyed by (series_id, album_id): two series can legitimately
        # include the same album id, and a last-writer-wins dict would
        # attribute the drift finding to whichever entry came second.
        wanted: dict[tuple[str, str], tuple[CatalogEntry, dict]] = {}
        for entry in entries:
            records = stored_album_records(
                entry.id, provider.name, included_only=included_only
            )
            for message in configured_vs_curation(entry, provider.name):
                provider_result.divergence.append(message)
            if not records and entry.provider_album_ids(provider.name):
                provider_result.unresolved_series.append(f"{entry.id}/{provider.name}")
                continue
            for record in records:
                album_id = str(record.get("album_id") or "")
                if album_id:
                    wanted[(entry.id, album_id)] = (entry, record)

        if not wanted:
            return provider_result

        # One provider request per distinct album id; duplicates that span
        # series are fetched once and compared per (series, album).
        distinct_ids = sorted({album_id for _, album_id in wanted})
        on_progress(
            f"{provider.name}: checking {len(distinct_ids)} albums "
            f"across {len(wanted)} series entries"
        )
        fetched = provider.albums_by_ids(distinct_ids)
        live: dict[str, Album] = {a.id: a for a in fetched.albums}
        unverified = set(fetched.unverified)
        provider_result.unverified.extend(
            f"{provider.name}:{i}" for i in sorted(unverified)
        )
        provider_result.checked[provider.name] = len(distinct_ids) - len(unverified)

        for (_series_id, album_id), (entry, record) in wanted.items():
            if album_id in unverified:
                # Lookup failed: we know nothing about this album, and
                # guessing "gone" here would turn an outage into a mass
                # deletion report.
                continue
            hit = live.get(album_id)
            finding = classify_album_drift(
                album_id=album_id,
                provider=provider.name,
                stored_title=str(record.get("title") or ""),
                stored_episode=record.get("episode_num"),
                stored_release=record.get("release_date"),
                live_title=hit.name if hit else None,
                live_release=hit.release_date if hit else None,
                pattern=entry.effective_pattern(provider.name),
                series_id=entry.id,
            )
            if finding is not None:
                provider_result.findings.append(finding)
        return provider_result

    per_provider = map_providers(sweep, providers)

    result = DriftResult()
    for provider in providers:
        provider_result = per_provider[provider.name]
        result.divergence.extend(provider_result.divergence)
        result.unresolved_series.extend(provider_result.unresolved_series)
        result.unverified.extend(provider_result.unverified)
        result.checked.update(provider_result.checked)
        result.findings.extend(provider_result.findings)

    result.findings.sort(
        key=lambda f: (
            list(DriftSeverity).index(f.severity),
            f.series_id,
            f.provider,
        )
    )
    return result


def apply_cosmetic_titles(result: DriftResult) -> int:
    """Adopt the provider's wording for cosmetic-only title changes.

    Only `info` findings are touched: the normalised titles already
    match, so this is punctuation and store-suffix hygiene, never a
    content decision. Returns the number of records updated.
    """
    from lauschi_catalog.catalog.io import safe_write_json

    by_series: dict[str, list[DriftFinding]] = {}
    for f in result.findings:
        if f.is_cosmetic and f.live_title:
            by_series.setdefault(f.series_id, []).append(f)

    updated = 0
    for series_id, findings in by_series.items():
        path = curation_path(series_id)
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        wanted = {(f.provider, f.album_id): f.live_title for f in findings}
        touched = False
        for album in data.get("albums", []):
            key = (album.get("provider"), album.get("album_id"))
            live_title = wanted.get(key)
            if live_title and album.get("title") != live_title:
                album["title"] = live_title
                touched = True
                updated += 1
        if touched:
            safe_write_json(path, data)
    return updated
