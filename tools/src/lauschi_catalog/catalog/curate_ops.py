"""Library functions for AI-assisted series curation.

Pydantic models, agent builders, async orchestration, and persistence.
Interactive prompts and Rich display stay in the CLI layer
(commands/curate.py). Progress is reported via callbacks so both CLI
and web UI can consume it.
"""

import asyncio
import json
import os
import re
import time
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, date, datetime
from pathlib import Path
from typing import ClassVar, Literal

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_ai import Agent, ModelRetry, RunContext
from pydantic_ai.messages import ModelMessage, ModelMessagesTypeAdapter
from pydantic_ai.usage import RunUsage

from lauschi_catalog._opencode import (
    build_model,
    get_model_settings,
)
from lauschi_catalog.agent_deps import AgentDeps, Progress, _noop
from lauschi_catalog.agent_hooks import build_progress_hooks
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.catalog.add_ops import title_to_id
from lauschi_catalog.catalog.analysis import analyze_series, normalize_title
from lauschi_catalog.catalog.canonical import album_sort_key, canonicalize
from lauschi_catalog.catalog.facts import (
    EraBoundary,
    EraBoundaryProposal,
    KnownGap,
    KnownGapProposal,
    SeriesFacts,
    SubSeriesFact,
    SubSeriesProposal,
    fact_provenance,
    facts_from_curation,
    merge_facts,
)
from lauschi_catalog.catalog.io import load_curation, safe_write_json
from lauschi_catalog.catalog.lint_ops import (
    compress_runs,
    lint_curation,
    lint_regression,
)
from lauschi_catalog.catalog.loader import (
    load_catalog,
    lookup_catalog_entry,
    sibling_series,
)
from lauschi_catalog.catalog.matcher import (
    compute_pattern_coverage as _compute_pattern_coverage,
)
from lauschi_catalog.catalog.matcher import (
    extract_episode,
    spread_sample,
)
from lauschi_catalog.catalog.models import CatalogEntry
from lauschi_catalog.catalog.paths import (
    cover_cache_dir,
    cover_cache_path,
    curation_path,
    log_dir,
)
from lauschi_catalog.catalog.prompt import album_to_dict, format_albums_xml
from lauschi_catalog.catalog.series_ops import split_off_refusal
from lauschi_catalog.fanout import run_bounded
from lauschi_catalog.prompts import load_curate_skill
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.rate_limit import run_with_rate_limit_retry
from lauschi_catalog.retry import describe_failure
from lauschi_catalog.run import run_agent, run_with_attempts, usage_summary
from lauschi_catalog.run_events import (
    OUTCOME_FAILED,
    OUTCOME_OK,
    OUTCOME_SKIPPED,
    RunEvent,
    record_event,
)

_DEFAULT_MODEL = "kimi-k2.6"

_BATCH_SIZE = 30


# ── Pure helpers ──────────────────────────────────────────────────────────


#: ``\\d`` and friends: a literal backslash followed by a class letter.
#: Compiles, never matches. Rejected at entry so no repair is needed
#: downstream (see docs/catalog-episode-numbers.md).
_DOUBLE_ESCAPED_SHORTCUT = re.compile(r"\\\\[dDwWsShHbB]")


def _validate_episode_pattern(v: str | list[str] | None) -> str | list[str] | None:
    """Validate an episode_pattern before it can reach the catalog.

    Requires a capture group, and refuses double-escaped shortcuts: they
    compile but match a literal backslash, so they silently never fire.
    """
    if v is None:
        return None
    patterns = [v] if isinstance(v, str) else v
    for p in patterns:
        c = re.compile(p)
        if c.groups < 1:
            msg = f"Pattern {p!r}: needs at least 1 capture group"
            raise ValueError(msg)
        if _DOUBLE_ESCAPED_SHORTCUT.search(p):
            msg = (
                f"Pattern {p!r}: double-escaped shortcut matches a literal "
                f"backslash and never an episode number. Use one backslash."
            )
            raise ValueError(msg)
    return v


def curation_from_decisions(
    decisions: Sequence[AlbumDecision],
    pattern: str | list[str] | None,
    series_facts: dict | None = None,
) -> dict:
    """The partial-curation dict lint and analyze read.

    Three inline copies of this shape existed (batch structural hints,
    the finalize lint tool, the finalize analysis); one builder feeds
    all so the key set cannot drift between them. analyze ignores the
    exclude_reason key, lint requires it, so it is always carried.
    """

    def fields(d: AlbumDecision) -> dict:
        return {
            "album_id": d.album_id,
            "provider": d.provider,
            "include": d.include,
            "title": d.title,
            "episode_num": d.episode_num,
            "release_date": d.release_date,
            "exclude_reason": d.exclude_reason,
        }

    partial: dict = {
        "albums": [fields(d) for d in decisions],
        "episode_pattern": pattern,
    }
    if series_facts is not None:
        partial["series_facts"] = series_facts
    return partial


def build_structural_hints(analysis: dict) -> list[str]:
    """Human-readable analysis signals fed back into the next batch."""
    hints: list[str] = []
    if analysis.get("gaps"):
        hints.append(f"Missing episodes so far: {analysis['gaps']}")
    for dup in analysis.get("duplicates_within_provider") or []:
        hints.append(
            f"Duplicate episodes on {dup['provider']}: ep {dup['episode_num']}"
        )
    xpc = analysis.get("cross_provider_coverage") or {}
    missing_per = xpc.get("missing_per_provider") or {}
    for prov, missing_eps in missing_per.items():
        if missing_eps:
            hints.append(f"{prov} missing episodes: {missing_eps}")
    clusters = analysis.get("title_clusters") or []
    for c in clusters:
        examples = ", ".join(c["examples"][:3])
        hints.append(f"Title cluster {c['shape']!r} ({c['count']} albums): {examples}")
    return hints


def format_batch_albums(
    batch: list[dict],
    seen_details: dict[str, dict],
) -> list[dict]:
    """Normalize a batch to unified album dicts for the prompt XML.

    Full details where the prefetch has them; explicit fallback keys
    (the same shape prompt.album_to_dict emits) where it does not.
    """
    albums: list[dict] = []
    for a in batch:
        key = f"{a['provider']}:{a['id']}"
        detail = seen_details.get(key)
        if detail:
            albums.append(album_to_dict(detail))
            continue
        albums.append(
            {
                "provider": a["provider"],
                "id": a["id"],
                "title": a["name"],
                "episode_num": None,
                "release_date": a.get("release_date", ""),
                "album_type": a.get("album_type", ""),
                "total_tracks": a.get("total_tracks", 0),
                "duration_min": None,
                "label": "",
                "artist": "",
                "tracks": [],
            }
        )
    return albums


def build_batch_prompt(
    *,
    series_title: str,
    pattern: str | list[str] | None,
    progress_text: str,
    rolling: str,
    structural_hints: list[str],
    sibling_titles: list[str],
    batch_num: int,
    n_batches: int,
    n_albums: int,
    albums_xml: str,
) -> str:
    """Assemble the per-batch user prompt. Pure; snapshot-tested."""
    prompt = f"Series: {series_title!r}\nEpisode pattern: {pattern}\n{progress_text}\n"
    if rolling:
        prompt += f"{rolling}\n"
    if structural_hints:
        prompt += (
            "Structural signals from prior batches:\n"
            + "\n".join(f"  {h}" for h in structural_hints)
            + "\n\n"
        )
    if sibling_titles:
        prompt += (
            "Sibling series that exist as their own catalog entries. An album "
            "that belongs to one of them is sub_series_bleed, not part of this "
            "series:\n" + "\n".join(f"  - {t}" for t in sibling_titles) + "\n\n"
        )
    prompt += f"\nBatch {batch_num}/{n_batches} ({n_albums} albums):\n\n{albums_xml}"
    return prompt


def _build_batch_summary(
    decisions: list["AlbumDecision"],
    pattern: str | list[str] | None,
    batch_num: int,
) -> str:
    """Produce a concise rolling summary for the next batch prompt.

    Prior batches' decisions are summarized so the agent can stay
    consistent: which episode numbers are already included, what
    pattern is active, what kinds of albums are being excluded.

    Episodes are grouped by provider so the agent knows whether a
    given episode has been included on the CURRENT provider or only
    on another one.  This prevents cross-provider duplicates from
    being wrongly excluded.
    """
    included = [d for d in decisions if d.include]
    excluded = [d for d in decisions if not d.include]

    lines: list[str] = []

    if included:
        eps_by_provider: dict[str, list[int]] = {}
        for d in included:
            if d.episode_num is not None:
                eps_by_provider.setdefault(d.provider, []).append(d.episode_num)

        if eps_by_provider:
            lines.append("Prior included episodes (by provider):")
            for prov in sorted(eps_by_provider):
                eps = sorted(set(eps_by_provider[prov]))
                lines.append(f"  {prov}: {compress_runs(eps)}")

    if pattern is not None:
        pat_str = pattern if isinstance(pattern, str) else " | ".join(pattern)
        lines.append(f"Active pattern: {pat_str!r}")

    if excluded:
        reasons: dict[str, int] = {}
        for d in excluded:
            r = d.exclude_reason or "unspecified"
            reasons[r] = reasons.get(r, 0) + 1
        top = sorted(reasons.items(), key=lambda kv: kv[1], reverse=True)[:3]
        if top:
            reason_lines = [f"  {r} ({n})" for r, n in top]
            lines.append("Prior exclusions:")
            lines.extend(reason_lines)

    if batch_num > 1 and not lines:
        lines.append("No decisions from prior batches yet.")

    return "\n".join(lines) if lines else ""


def _inject_split_children(
    existing_curation: dict | None,
    series_id: str | None,
) -> dict | None:
    """Add split children's albums as pre-excluded to the parent curation.

    Looks up the catalog for entries with split_from == series_id,
    loads their curation files, and injects their albums as excluded
    with sub_series_bleed. This way _preseed_decisions carries them
    forward and the batch agent never sees them as undecided.
    """
    if not series_id:
        return existing_curation

    catalog = load_catalog()
    children = [e for e in catalog if e.split_from == series_id]
    if not children:
        return existing_curation

    if existing_curation is None:
        existing_curation = {"albums": []}

    existing_keys = {
        (a.get("provider"), a.get("album_id"))
        for a in existing_curation.get("albums", [])
    }

    for child in children:
        for provider, album_id, title in _child_album_records(child):
            key = (provider, album_id)
            if key in existing_keys:
                continue
            existing_curation.setdefault("albums", []).append(
                {
                    "album_id": album_id,
                    "provider": provider,
                    "title": title,
                    "include": False,
                    "exclude_reason": "sub_series_bleed",
                    "confidence": "high",
                    "notes": f"Belongs to split series '{child.id}'",
                    "release_date": None,
                }
            )
            existing_keys.add(key)

    return existing_curation


def _child_album_records(child) -> list[tuple[str, str, str]]:
    """(provider, album_id, title) for a split child's albums.

    series.yaml is the authoritative, always-present source; the
    child's curation file is a fallback for a child that was curated
    but not yet applied.
    """
    records: list[tuple[str, str, str]] = []
    for provider, cfg in child.providers.items():
        for album in cfg.albums:
            records.append((provider, album["id"], album.get("title", "")))
    if records:
        return records
    child_path = curation_path(child.id)
    if not child_path.exists():
        return []
    child_data = json.loads(child_path.read_text())
    return [
        (a.get("provider", ""), a.get("album_id", ""), a.get("title", ""))
        for a in child_data.get("albums", [])
        if a.get("album_id")
    ]


def _settle_same_provider_duplicates(
    decisions: list["AlbumDecision"],
    era_boundaries: list[EraBoundary],
) -> list["AlbumDecision"]:
    """Resolve same-provider duplicates by the era fact, not a year window.

    Two included albums on one provider with the same episode number and
    the same title are the same release twice (a re-pressing, a remaster)
    unless an era_boundary fact places them in different eras (a
    re-recording decades apart). Without such a fact the newest wins and
    the other is marked duplicate; with one, both stay. The fact is the
    authority, so the outcome is the same on every run.
    """
    groups: dict[tuple[str, int, str], list[int]] = {}
    for i, d in enumerate(decisions):
        if not d.include or d.episode_num is None:
            continue
        key = (d.provider, d.episode_num, normalize_title(d.title))
        groups.setdefault(key, []).append(i)

    def era_of(d: "AlbumDecision") -> int | None:
        year = _release_year(d.release_date)
        if year is None:
            return None
        for n, era in enumerate(era_boundaries):
            if era.contains_year(year):
                return n
        return None

    settled = list(decisions)
    for members in groups.values():
        if len(members) < 2:
            continue
        eras = {era_of(decisions[i]) for i in members}
        if len(eras) > 1 and None not in eras:
            continue  # an era fact separates them: different recordings
        newest = max(members, key=lambda i: decisions[i].release_date or "")
        for i in members:
            if i == newest:
                continue
            settled[i] = decisions[i].model_copy(
                update={
                    "include": False,
                    "exclude_reason": "duplicate",
                    "confidence": "high",
                    "notes": (
                        f"Same episode and title on this provider as "
                        f"{decisions[newest].album_id} "
                        f"({decisions[newest].release_date}); no era_boundary "
                        f"separates them, the newest release is kept."
                    ),
                }
            )
    return settled


def _release_year(release_date: str | None) -> int | None:
    if release_date and len(release_date) >= 4 and release_date[:4].isdigit():
        return int(release_date[:4])
    return None


def _pre_decide_future_releases(
    remaining: list[dict],
    *,
    today: "date | None" = None,
) -> tuple[list["AlbumDecision"], list[dict]]:
    """Settle not-yet-released albums before the batch phase.

    A discovered album whose release date is in the future is not
    available yet, so it must not ship, and the decision must be the
    same every run rather than left to the model (an Apple album dated
    2026-10-02 made two clean Kira runs disagree). A later re-curate
    includes it once the date has passed. Year-only or missing dates
    are ambiguous and left to the batch. Excludes on every provider
    that has the album, so reconcile has no included counterpart to
    flip it back to.
    """
    cutoff = (today or date.today()).isoformat()
    decided: list[AlbumDecision] = []
    still: list[dict] = []
    for a in remaining:
        rd = a.get("release_date")
        if rd and len(str(rd)) >= 10 and str(rd) > cutoff:
            decided.append(
                AlbumDecision(
                    album_id=a["id"],
                    provider=a["provider"],
                    include=False,
                    episode_num=None,
                    title=a.get("name", ""),
                    exclude_reason="partial_release",
                    confidence="high",
                    release_date=str(rd),
                    notes=f"Release date {rd} is in the future; not available yet.",
                )
            )
        else:
            still.append(a)
    return decided, still


def _preseed_decisions(
    all_albums: list[dict],
    existing_curation: dict | None,
) -> tuple[list["AlbumDecision"], list[dict]]:
    """Carry forward decisions from a prior (possibly incomplete) curation.

    Returns (carried_decisions, remaining_albums) where remaining_albums
    is the subset of all_albums not already decided.

    Invalid carried albums are surfaced as curation errors rather than
    silently dropped, so a bad `exclude_reason` or malformed field does
    not get re-decided by the model behind the operator's back.
    """
    if not existing_curation or not existing_curation.get("albums"):
        return [], all_albums

    discovered_ids = {(a["provider"], a["id"]) for a in all_albums}
    carried: list["AlbumDecision"] = []
    errors: list[str] = []
    for ea in existing_curation["albums"]:
        key = (ea.get("provider", ""), ea.get("album_id", ""))
        if key not in discovered_ids:
            continue
        try:
            carried.append(
                AlbumDecision(
                    album_id=ea["album_id"],
                    provider=ea["provider"],
                    include=ea["include"],
                    episode_num=ea.get("episode_num"),
                    title=ea.get("title", ""),
                    exclude_reason=ea.get("exclude_reason"),
                    release_date=ea.get("release_date"),
                    confidence=ea.get("confidence", "high"),
                    notes=ea.get("notes"),
                )
            )
        except Exception as exc:
            errors.append(f"{key}: {exc}")

    if errors:
        raise ValueError(
            "Prior curation contains invalid album records; fix or re-curate with --force.\n"
            + "\n".join(errors)
        )

    if not carried:
        return [], all_albums

    carried_ids = {(d.provider, d.album_id) for d in carried}
    remaining = [a for a in all_albums if (a["provider"], a["id"]) not in carried_ids]
    return carried, remaining


def drop_orphan_decisions(
    decisions: list["AlbumDecision"],
    batch_ids: set[tuple[str, str]],
    on_progress: Progress = _noop,
) -> tuple[list["AlbumDecision"], list[str]]:
    """Keep only decisions for albums that were in the batch.

    A model can answer with an id it was never given: a plausible
    provider id attached to a real title. Luna did this once on Bibi
    Blocksberg (apple_music 1143565835, "Folge 75: Die neue Lehrerin",
    an id Apple Music does not have). Such a decision is an invented
    album; kept, it would ship into series.yaml through apply and the
    app would show a tile that cannot play. Returns the kept decisions
    and the dropped ``provider:album_id`` keys.
    """
    kept: list[AlbumDecision] = []
    orphans: list[str] = []
    for d in decisions:
        if (d.provider, d.album_id) in batch_ids:
            kept.append(d)
            continue
        key = f"{d.provider}:{d.album_id}"
        orphans.append(key)
        on_progress(
            f"  Dropped decision for {key} ({d.title!r}): not an album in this batch"
        )
    return kept, orphans


def _stratified_sample(items: list, n: int) -> list:
    """Pick ``n`` items spread evenly across ``items`` rather than
    taking the head.

    Provider APIs return albums in some order (Spotify: roughly
    newest-first). Taking the first N can blind the metadata agent
    to era-specific naming conventions.
    """
    return spread_sample(items, n)


def _reextract_episode_numbers(
    decisions: list["AlbumDecision"],
    pattern: str | list[str] | None,
) -> int:
    """Re-run episode extraction on all decisions with a (possibly revised)
    pattern. Returns the number of decisions whose episode_num changed."""
    if pattern is None:
        return 0
    changed = 0
    for d in decisions:
        new_ep = extract_episode(pattern, d.title)
        if new_ep is not None and new_ep != d.episode_num:
            d.episode_num = new_ep
            changed += 1
    return changed


# ── Output models ─────────────────────────────────────────────────────────


ExcludeReason = Literal[
    "compilation",
    "kinderlieder_compilation",
    "multi_artist_compilation",
    "wrong_content_type",
    "music_single",
    "format_variant",
    "sub_series_bleed",
    "duplicate",
    "not_kids_content",
    "different_series",
    "partial_release",
    "unspecified",
]


class AlbumDecision(BaseModel):
    """Decision for a single album from any provider."""

    album_id: str
    provider: str  # "spotify" or "apple_music"
    include: bool
    episode_num: int | None = Field(
        description="Episode number extracted from the album title using the series episode_pattern regex"
    )
    title: str
    exclude_reason: ExcludeReason | None = None
    release_date: str | None = None
    confidence: Literal["high", "medium", "low"] = "high"
    notes: str | None = Field(
        default=None,
        description=(
            "Required when confidence != 'high'. Name the failure-"
            "taxonomy pattern that almost matched, or describe what's "
            "missing. Empty/None when confidence == 'high'."
        ),
    )

    @model_validator(mode="after")
    def _notes_required_when_unsure(self) -> "AlbumDecision":
        if self.confidence != "high" and not self.notes:
            raise ValueError(
                "confidence != 'high' requires `notes` describing why",
            )
        return self

    @model_validator(mode="after")
    def _exclude_reason_required_when_excluded(self) -> "AlbumDecision":
        if not self.include and not self.exclude_reason:
            self.exclude_reason = "unspecified"
        return self


_EPISODE_PATTERN_DESCRIPTION = (
    "Regex(es) with one capture group that yields an integer episode "
    "number (`int(group)` MUST succeed). Use None when titles carry "
    "no digit-string episode markers — e.g. named episodes (fairy "
    "tales, themed releases), sequel markers like 'Inside Out 2', or "
    "story-based titles. When None, albums display sorted by "
    "release_date in the UI; there is NO penalty for None and no "
    "benefit to inventing a catch-all. Do NOT emit '(\\\\d+)' just "
    "to populate this field: that captures any digit anywhere in a "
    "title and silently breaks when the catalog grows to include "
    "albums with years, volume counts, or anniversary numbers."
)

_EPISODE_PATTERN_EXAMPLES = [
    None,
    r"^Folge (\d+):",
    [r"^(\d{3})/", r"^Folge (\d+):"],
]


class CuratedSeries(BaseModel):
    """Complete curation result for a series or music artist."""

    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = Field(
        default=None,
        description=_EPISODE_PATTERN_DESCRIPTION,
        examples=_EPISODE_PATTERN_EXAMPLES,
    )
    albums: list[AlbumDecision]
    provider_artist_ids: dict[str, list[str]] = Field(default_factory=dict)
    age_note: str = ""
    curator_notes: str = ""
    content_type: Literal["hoerspiel", "music", "audiobook"] = "hoerspiel"
    series_facts: SeriesFacts = Field(default_factory=SeriesFacts)
    incomplete: bool = False
    incomplete_reason: str = ""
    curated_by: str = ""
    #: requests / input_tokens / output_tokens spent producing this
    usage: dict[str, int] = Field(default_factory=dict)
    #: ``provider:album_id`` decisions the model returned for albums it
    #: was never given; dropped, see drop_orphan_decisions
    orphan_ids: list[str] = Field(default_factory=list)
    # Deterministic regressions vs the previous curation (see
    # lint_ops.lint_regression). CRITICAL entries hard-gate audit
    # approval.
    regression_flags: list[str] = Field(default_factory=list)

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        return _validate_episode_pattern(v)

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            key=lambda a: album_sort_key(a.model_dump()),
        )

    def by_provider(self, provider: str) -> list[AlbumDecision]:
        return [a for a in self.included() if a.provider == provider]


class BatchResult(BaseModel):
    """Decisions for one batch of albums."""

    albums: list[AlbumDecision]


class SeriesMetadata(BaseModel):
    """Metadata extracted in the first phase (no album decisions)."""

    id: str = Field(pattern=r"^[a-z][a-z0-9_]*$")
    title: str
    aliases: list[str] = Field(default_factory=list)
    episode_pattern: str | list[str] | None = Field(
        default=None,
        description=_EPISODE_PATTERN_DESCRIPTION,
        examples=_EPISODE_PATTERN_EXAMPLES,
    )
    age_note: str = ""
    curator_notes: str = ""

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        return _validate_episode_pattern(v)


# ── Agent dependencies ────────────────────────────────────────────────────


@dataclass
class CurateDeps(AgentDeps):
    """Dependency container for all curate-phase agents."""

    pattern: str | list[str] | None = None
    pattern_revisions: list[str | list[str]] = field(default_factory=list)
    titles: list[str] = field(default_factory=list)
    existing_facts: SeriesFacts = field(default_factory=SeriesFacts)
    proposed_facts: SeriesFacts | None = field(default=None, init=False)
    all_decisions: list[AlbumDecision] = field(default_factory=list)
    current_batch_ids: set[tuple[str, str]] = field(default_factory=set, init=False)
    #: requests and tokens across every agent run that shares these deps
    usage: RunUsage = field(default_factory=RunUsage)
    _pattern_check_count: int = field(default=0, init=False)
    _MAX_PATTERN_CHECKS: ClassVar[int] = 5


class EpisodeUpdate(BaseModel):
    """One album whose episode number was discovered from track listings."""

    album_id: str
    provider: str
    episode_num: int


class PatternCoverageReport(BaseModel):
    """Result of testing an episode_pattern against the full discography."""

    pattern: str | list[str] | None = None
    matched: int = 0
    total: int = 0
    coverage: float = 0.0
    unmatched_regex_samples: list[str] = Field(default_factory=list)
    non_numeric_capture_samples: list[dict[str, str]] = Field(default_factory=list)
    limit_reached: bool = False
    message: str = ""


class FinalizeResult(BaseModel):
    """Output of the metadata-finalization agent."""

    episode_updates: list[EpisodeUpdate] = Field(
        default_factory=list,
        description="Albums where track listings revealed the episode number.",
    )


def _pattern_coverage_report(
    titles: list[str],
    pattern: str | list[str],
    *,
    max_samples: int = 15,
) -> PatternCoverageReport:
    """Run compute_pattern_coverage and map the result to a report.

    Errors (invalid regex, missing capture group) land in ``message``
    so the model can read what went wrong; an all-zeros report with no
    explanation reads as "the pattern matched nothing" and sends the
    model down wrong paths.
    """
    raw = _compute_pattern_coverage(titles, pattern, max_samples=max_samples)
    if "error" in raw:
        return PatternCoverageReport(pattern=pattern, message=raw["error"])
    return PatternCoverageReport(
        pattern=raw.get("pattern"),
        matched=raw.get("matched", 0),
        total=raw.get("total", 0),
        coverage=raw.get("coverage", 0.0),
        unmatched_regex_samples=raw.get("unmatched_regex_samples", []),
        non_numeric_capture_samples=raw.get("non_numeric_capture_samples", []),
    )


def pattern_update_impact(
    old: str | list[str] | None,
    new: str | list[str],
    included_titles: list[str],
    excluded_titles: list[str],
) -> dict:
    """Compare a proposed episode_pattern against the current one.

    Two axes: coverage of included titles (a drop means episodes lose
    their numbers, which can be deliberate denoising) and matches on
    excluded titles (an increase means stray digits would be captured;
    the merged-regex failure mode). ``rejected`` is set only when the
    new pattern is below the 30% coverage floor AND worse than the old
    one; improving from a bad baseline is always allowed.
    """

    def _cov(pattern, titles):
        if pattern is None:
            return 0
        return sum(1 for t in titles if extract_episode(pattern, t) is not None)

    old_inc = _cov(old, included_titles)
    new_inc = _cov(new, included_titles)
    old_exc = _cov(old, excluded_titles)
    new_exc = _cov(new, excluded_titles)
    total = len(included_titles)

    lines = [f"Coverage on included titles: {new_inc}/{total} (was {old_inc}/{total})."]
    if new_inc < old_inc:
        lines.append(
            f"WARNING: {old_inc - new_inc} included title(s) lose their "
            f"episode number under the new pattern. Intentional denoising "
            f"is fine; verify those titles are noise, not episodes."
        )
    if new_exc > old_exc:
        lines.append(
            f"WARNING: the new pattern matches {new_exc} excluded title(s) "
            f"(was {old_exc}). Digits captured from non-episode content "
            f"corrupt episode numbers; prefer one anchored regex per "
            f"naming convention."
        )

    rejected = None
    if total and new_inc < total * 0.3 and new_inc < old_inc:
        rejected = (
            f"Coverage {new_inc}/{total} is below the 30% floor and worse "
            f"than the current pattern ({old_inc}/{total}). Keep the "
            f"current pattern or extend it instead."
        )

    return {
        "old_included": old_inc,
        "new_included": new_inc,
        "old_excluded_matches": old_exc,
        "new_excluded_matches": new_exc,
        "report": " ".join(lines),
        "rejected": rejected,
    }


# ── Agent builders ────────────────────────────────────────────────────────


def _build_metadata_agent(
    model,
    *,
    model_name: str = "",
    content_type: str = "hoerspiel",
    discography_span_years: int | None = None,
) -> Agent[CurateDeps, SeriesMetadata]:
    """Metadata-extraction agent.

    For Hoerspiel series, the agent must call check_pattern_coverage
    before finalizing. For music and audiobook artists, episode_pattern
    is meaningless so the tool isn't registered.
    """
    skill_instructions = load_curate_skill(
        phase="metadata",
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    agent: Agent[CurateDeps, SeriesMetadata] = Agent(
        model,
        output_type=SeriesMetadata,
        instructions=skill_instructions,
        model_settings=get_model_settings("curate", model_name),
        retries={"tools": 2, "output": 2},
        toolsets=[build_agent_tools()],
        capabilities=[build_progress_hooks()],
    )

    if content_type in ("music", "audiobook"):
        return agent

    @agent.output_validator
    def _validate_metadata(
        ctx: RunContext[CurateDeps], meta: SeriesMetadata
    ) -> SeriesMetadata:
        """Post-output validation: ensure the agent tested its pattern."""
        if ctx.deps._pattern_check_count == 0:
            raise ModelRetry(
                "You must call check_pattern_coverage with your proposed "
                "episode_pattern before returning. If titles genuinely carry "
                "no episode numbers, set episode_pattern=None.",
            )
        if meta.episode_pattern:
            matched = sum(
                1
                for t in ctx.deps.titles
                if extract_episode(meta.episode_pattern, t) is not None
            )
            total = len(ctx.deps.titles)
            coverage = matched / total if total else 0
            if coverage < 0.3:
                raise ModelRetry(
                    f"Coverage only {coverage:.0%} ({matched}/{total}). "
                    f"Legitimate episodes are being missed. Add a new regex "
                    f"pattern that matches the unmatched titles, or set "
                    f"episode_pattern=None if this series truly has no "
                    f"numbered episodes.",
                )
            if coverage < 0.8:
                ctx.deps.on_progress(
                    f"  [warning] Pattern coverage {coverage:.0%} "
                    f"({matched}/{total}) is below 80%. Unmatched albums "
                    f"may be sub-series, compilations, or non-episode content.",
                )
        return meta

    @agent.tool
    def check_pattern_coverage(
        ctx: RunContext[CurateDeps],
        pattern: str | list[str],
    ) -> PatternCoverageReport:
        """Test a proposed episode_pattern against ALL discovered titles.

        Accepts a single regex or a list of regexes (tried in order,
        first match wins). Use a list when naming conventions changed
        across eras; do NOT merge eras into one broad regex.

        Returns coverage stats. Each pattern's first capture group MUST
        capture a digit string (the episode number). A title can fail
        in two distinct ways:
          - unmatched_regex_samples: no regex found a match at all
          - non_numeric_capture_samples: a regex matched but capture
            group 1 wasn't an integer

        If ``message`` is non-empty, the pattern was rejected (invalid
        regex or missing capture group); fix it and check again.

        Limited to 5 calls per run.
        """
        ctx.deps._pattern_check_count += 1
        if ctx.deps._pattern_check_count > ctx.deps._MAX_PATTERN_CHECKS:
            ctx.deps.on_progress(
                f"  check_pattern_coverage limit reached "
                f"({ctx.deps._pattern_check_count - 1}/{ctx.deps._MAX_PATTERN_CHECKS}). "
                f"Set episode_pattern=None or commit to your best pattern.",
            )
            return PatternCoverageReport(
                limit_reached=True,
                message=f"Maximum {ctx.deps._MAX_PATTERN_CHECKS} pattern checks reached. "
                "Set episode_pattern=None if coverage is below 80%, "
                "or use your best pattern if coverage is acceptable.",
            )
        report = _pattern_coverage_report(ctx.deps.titles, pattern, max_samples=15)
        if report.message:
            ctx.deps.on_progress(
                f"  check_pattern_coverage({pattern!r}) -> error: {report.message}",
            )
        else:
            ctx.deps.on_progress(
                f"  check_pattern_coverage({pattern!r}) -> "
                f"{report.matched}/{report.total} = "
                f"{report.coverage:.0%}",
            )
        return report

    return agent


def _build_batch_agent(
    model,
    *,
    model_name: str = "",
    content_type: str = "hoerspiel",
    discography_span_years: int | None = None,
) -> Agent[CurateDeps, BatchResult]:
    """Agent for processing one batch of albums."""
    skill_instructions = load_curate_skill(
        phase="batch",
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    agent: Agent[CurateDeps, BatchResult] = Agent(
        model,
        output_type=BatchResult,
        instructions=skill_instructions,
        model_settings=get_model_settings("curate", model_name),
        retries={"tools": 2, "output": 2},
        toolsets=[build_agent_tools()],
        capabilities=[build_progress_hooks()],
    )

    @agent.output_validator
    def _validate_batch_completeness(
        ctx: RunContext[CurateDeps], result: BatchResult
    ) -> BatchResult:
        """Every album in the batch must have a decision, and no extras."""
        if not ctx.deps.current_batch_ids:
            return result
        returned_ids = {(a.provider, a.album_id) for a in result.albums}
        batch_ids = ctx.deps.current_batch_ids
        missing = batch_ids - returned_ids
        extra = returned_ids - batch_ids
        if missing or extra:
            samples_missing = [f"{p}:{aid}" for p, aid in sorted(missing)[:5]]
            samples_extra = [f"{p}:{aid}" for p, aid in sorted(extra)[:5]]
            parts: list[str] = []
            if missing:
                parts.append(
                    f"omitted {len(missing)} album(s). Missing: "
                    f"{', '.join(samples_missing)}"
                    f"{'...' if len(missing) > 5 else ''}"
                )
            if extra:
                parts.append(
                    f"added {len(extra)} extra album(s). Extra: "
                    f"{', '.join(samples_extra)}"
                    f"{'...' if len(extra) > 5 else ''}"
                )
            raise ModelRetry(
                f"Your output does not match the batch exactly. "
                f"{'; '.join(parts)}. "
                f"Return one decision for every album in the batch and no others.",
            )
        return result

    return agent


def _search_included_albums(
    decisions: list["AlbumDecision"],
    query: str,
) -> list[dict]:
    """Search included albums by title keyword (case-insensitive).

    Returns dicts with album_id, provider, title, episode_num for each match.
    Used by the finalize agent to look up album IDs when building
    sub_series proposals and to check numbering state without needing
    get_album_details.
    """
    q = query.lower()
    return [
        {
            "album_id": d.album_id,
            "provider": d.provider,
            "title": d.title,
            "episode_num": d.episode_num,
        }
        for d in decisions
        if d.include and q in d.title.lower()
    ]


def _build_finalize_agent(
    model,
    *,
    model_name: str = "",
    content_type: str = "hoerspiel",
    discography_span_years: int | None = None,
) -> Agent[CurateDeps, FinalizeResult]:
    """Agent for post-batch metadata finalization."""
    skill_instructions = load_curate_skill(
        phase="finalize",
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    agent: Agent[CurateDeps, FinalizeResult] = Agent(
        model,
        output_type=FinalizeResult,
        instructions=skill_instructions,
        model_settings=get_model_settings("finalize", model_name),
        retries={"tools": 2, "output": 2},
        toolsets=[build_agent_tools()],
        capabilities=[build_progress_hooks()],
    )

    @agent.tool
    def search_included_albums(
        ctx: RunContext[CurateDeps],
        query: str,
    ) -> list[dict]:
        """Search included albums by title keyword (case-insensitive).

        Returns album_id, provider, title, and episode_num for each match.
        Use this to find album_ids for sub_series proposals and to check
        numbering state without needing get_album_details.
        """
        results = _search_included_albums(ctx.deps.all_decisions, query)
        ctx.deps.on_progress(
            f"  search_included_albums({query!r}) -> {len(results)} hits",
        )
        return results

    @agent.tool
    def search_excluded_albums(
        ctx: RunContext[CurateDeps],
        query: str,
    ) -> list[dict]:
        """Search excluded albums by title keyword (case-insensitive).

        Returns results grouped by title. Each entry has title,
        exclude_reason, and album_ids (list of {album_id, provider}).
        Use this to collect album_ids for sub_series proposals.
        """
        q = query.lower()
        by_title: dict[str, dict] = {}
        for d in ctx.deps.all_decisions:
            if d.include or q not in d.title.lower():
                continue
            if d.title not in by_title:
                by_title[d.title] = {
                    "title": d.title,
                    "exclude_reason": d.exclude_reason,
                    "album_ids": [],
                }
            by_title[d.title]["album_ids"].append(
                {"album_id": d.album_id, "provider": d.provider},
            )
        results = sorted(by_title.values(), key=lambda x: x["title"])
        ctx.deps.on_progress(
            f"  search_excluded_albums({query!r}) -> {len(results)} titles",
        )
        return results

    @agent.tool
    def propose_pattern_update(
        ctx: RunContext[CurateDeps],
        patterns: list[str],
    ) -> str:
        """Propose an updated episode_pattern regex.

        Only use if track listings reveal a systematic new format that
        the current pattern doesn't catch. Verify the new pattern
        actually extracts digit/integer episode numbers from album
        titles. Extend the pattern list rather than merging conventions
        into one broad regex. Returns a deterministic impact report
        (coverage delta on included titles, matches on excluded
        titles); read its warnings.
        """
        if not patterns:
            raise ModelRetry("patterns list cannot be empty")
        for p in patterns:
            try:
                compiled = re.compile(p)
            except re.error as e:
                raise ModelRetry(f"invalid regex {p!r}: {e}")
            if compiled.groups < 1:
                raise ModelRetry(f"pattern {p!r}: needs >=1 capture group")

        if ctx.deps.titles:
            check = _compute_pattern_coverage(ctx.deps.titles, patterns)
            if "error" in check:
                raise ModelRetry(check["error"])
            if check["matched"] == 0:
                raise ModelRetry(
                    f"pattern {patterns!r}: didn't match any album titles. "
                    f"Track-name-only patterns are not useful here."
                )

        new_pattern: str | list[str] = (
            patterns[0] if len(patterns) == 1 else list(patterns)
        )
        impact = pattern_update_impact(
            ctx.deps.pattern,
            new_pattern,
            included_titles=[d.title for d in ctx.deps.all_decisions if d.include],
            excluded_titles=[d.title for d in ctx.deps.all_decisions if not d.include],
        )
        if impact["rejected"]:
            ctx.deps.on_progress(
                f"  finalize propose_pattern_update rejected: {impact['rejected']}",
            )
            raise ModelRetry(impact["rejected"])

        ctx.deps.pattern = new_pattern
        ctx.deps.on_progress(
            f"  finalize propose_pattern_update -> {new_pattern}\n"
            f"    {impact['report']}",
        )
        return f"Pattern updated to {new_pattern}. {impact['report']}"

    @agent.tool
    def lint_current_curation(
        ctx: RunContext[CurateDeps],
    ) -> list[str]:
        """Run deterministic structural checks on the current curation."""
        partial_curation = curation_from_decisions(
            ctx.deps.all_decisions,
            ctx.deps.pattern,
            series_facts=(
                ctx.deps.proposed_facts.model_dump()
                if ctx.deps.proposed_facts
                else None
            ),
        )
        issues = lint_curation(partial_curation)
        if issues:
            ctx.deps.on_progress(f"  Finalize lint: {len(issues)} issue(s)")
        return issues

    @agent.tool
    def propose_series_facts(
        ctx: RunContext[CurateDeps],
        era_boundaries: list[EraBoundaryProposal] = [],
        known_gaps: list[KnownGapProposal] = [],
        sub_series: list[SubSeriesProposal] = [],
    ) -> str:
        """Propose structured facts about the series."""
        empty_subs = [p.label for p in sub_series if not p.album_ids]
        if empty_subs:
            raise ModelRetry(
                f"sub_series {empty_subs} have no album_ids. "
                f"Without album_ids, downstream tools can't act on them. "
                f"Use search_included_albums to find matching albums, "
                f"then call propose_series_facts again with album_ids populated."
            )

        existing = ctx.deps.existing_facts
        if ctx.deps.proposed_facts is None:
            ctx.deps.proposed_facts = SeriesFacts()
        accumulated = ctx.deps.proposed_facts
        recorded: list[str] = []
        prov = fact_provenance(by="curate", at=datetime.now(UTC).isoformat())

        all_labels = {e.label for e in existing.era_boundaries} | {
            e.label for e in accumulated.era_boundaries
        }
        for proposal in era_boundaries:
            if proposal.label in all_labels:
                continue
            accumulated.era_boundaries.append(
                EraBoundary(**proposal.model_dump(), **prov),
            )
            recorded.append(f"era: {proposal.label}")
            all_labels.add(proposal.label)

        all_nums: set[int] = set()
        for g in existing.known_gaps:
            all_nums |= g.episode_numbers()
        for g in accumulated.known_gaps:
            all_nums |= g.episode_numbers()
        for proposal in known_gaps:
            prop_nums = set(
                range(proposal.number, (proposal.range_end or proposal.number) + 1)
            )
            if prop_nums & all_nums:
                continue
            accumulated.known_gaps.append(
                KnownGap(**proposal.model_dump(), **prov),
            )
            label = (
                f"{proposal.number}-{proposal.range_end}"
                if proposal.range_end
                else str(proposal.number)
            )
            recorded.append(f"gap: {label}")
            all_nums |= prop_nums

        all_labels = {s.label for s in existing.sub_series} | {
            s.label for s in accumulated.sub_series
        }
        for proposal in sub_series:
            if proposal.label in all_labels:
                continue
            accumulated.sub_series.append(
                SubSeriesFact(**proposal.model_dump(), **prov),
            )
            recorded.append(f"sub: {proposal.label}")
            all_labels.add(proposal.label)

        if not recorded:
            return "No new facts proposed (all already documented or empty)."

        ctx.deps.on_progress(
            f"  propose_series_facts -> {', '.join(recorded)}",
        )
        return f"Recorded {len(recorded)} new fact(s): {', '.join(recorded)}"

    return agent


# ── Async core ────────────────────────────────────────────────────────────


async def _run_agent(agent, prompt, deps):
    """Run an agent and return its structured output."""
    return await run_agent(
        agent, prompt, deps, request_limit=200, tally=getattr(deps, "usage", None)
    )


# Fresh-context attempts per batch before the series loses that batch. A
# batch fails on its own, not because of its prompt: Luna omitted one
# of 30 albums on Fünf Freunde batch 3 in two runs and passed the same
# batch in a third; it returned 1 of 30 on Bibi Blocksberg batch 8 and
# passed on the rerun; Kimi K2.5 hit its token limit on Hanni und Nanni
# batch 2. A second attempt starts from a fresh context (the in-run
# output retries keep the failed context, and failed again each time).
_BATCH_ATTEMPTS = 2


def dump_batch_failure(
    series_id: str,
    batch_num: int,
    prompt: str,
    messages: list[ModelMessage],
    exc: BaseException,
) -> Path:
    """Write what the model saw and answered for a batch that failed.

    A batch that exhausts its output retries takes the rest of the
    series with it (every later album is auto-included), so the
    exchange that led there is worth keeping: the exact prompt and
    every request/response, including the retry prompts and what the
    model returned to each. Returns the file written.
    """
    path = log_dir() / "curate-failures" / f"{series_id}-batch{batch_num:02d}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "series_id": series_id,
        "batch": batch_num,
        "error": describe_failure(exc),
        "prompt": prompt,
        "messages": json.loads(ModelMessagesTypeAdapter.dump_json(messages)),
    }
    path.write_text(json.dumps(payload, indent=1, ensure_ascii=False), encoding="utf-8")
    return path


def _fmt_elapsed(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    return f"{s // 60}m {s % 60:02d}s"


def _dedupe_albums(albums: list[dict]) -> list[dict]:
    """Drop repeated (provider, id) entries, keeping first occurrence.

    Series with multiple artist IDs per provider (e.g. a trio whose
    albums are credited to every member) fetch the same album once per
    artist page.
    """
    seen: set[tuple[str, str]] = set()
    result: list[dict] = []
    for a in albums:
        key = (a["provider"], a["id"])
        if key in seen:
            continue
        seen.add(key)
        result.append(a)
    return result


def _discovery_album_dict(provider_name: str, album) -> dict:
    """Convert a provider Album to the dict shape the curate flow uses.

    album_type (album/single/compilation, Spotify only) is part of the
    batch prompt: it lets the agent tell artist-own primary albums from
    repackaged compilations.
    """
    return {
        "provider": provider_name,
        "id": album.id,
        "name": album.name,
        "release_date": album.release_date,
        "total_tracks": album.total_tracks,
        "album_type": album.album_type,
        "image_url": album.image_url,
    }


async def _run_with_retry(
    coro_factory,
    *,
    phase: str = "",
    on_progress: Progress = _noop,
):
    return await run_with_rate_limit_retry(
        coro_factory,
        phase=phase,
        # The per-batch/phase timeout is an operation deadline, not a
        # transient blip: replaying a 3600 s timeout 12 times with
        # backoff could park one batch for close to a day. It counts
        # as one failed fresh-context attempt instead.
        retry_timeout=False,
        on_progress=on_progress,
    )


@dataclass
class DiscoveryResult:
    """Result of the provider discovery step in _run_large."""

    all_albums: list[dict]
    artist_ids: dict[str, list[str]]
    provider_errors: list[str]
    incomplete: bool


async def _run_discovery(
    query: str,
    providers: list[CatalogProvider],
    *,
    known_artist_ids: dict[str, list[str]] | None = None,
    on_progress: Progress = _noop,
) -> DiscoveryResult:
    """Discover albums for each configured/searched artist.

    Returns the raw discovery albums, the chosen artist ids, any
    provider errors, and whether the run should be considered
    incomplete (e.g. one provider returned zero albums while another
    returned some).
    """
    on_progress("\n== Discovery ==\n")

    all_albums: list[dict] = []
    artist_ids: dict[str, list[str]] = {}
    known_artist_ids = known_artist_ids or {}
    provider_errors: list[str] = []
    provider_album_counts: dict[str, int] = {}

    for p in providers:
        known = known_artist_ids.get(p.name) or []
        try:
            if known:
                for aid in known:
                    artist_ids.setdefault(p.name, []).append(aid)
                    albums = p.artist_albums(aid)
                    on_progress(
                        f"  [{p.name}] canonical artist: [{aid}] -> {len(albums)} albums",
                    )
                    all_albums.extend(_discovery_album_dict(p.name, a) for a in albums)
                    provider_album_counts[p.name] = provider_album_counts.get(
                        p.name, 0
                    ) + len(albums)
                continue

            artists = p.search_artists(query)
            if not artists:
                on_progress(f"  [{p.name}] No artist found")
                continue

            artist = artists[0]
            artist_ids.setdefault(p.name, []).append(artist.id)
            if len(artists) > 1:
                others = ", ".join(a.name for a in artists[1:4])
                on_progress(
                    f"  [{p.name}] chose {artist.name} "
                    f"[{artist.id}] (also matched: {others})",
                )
            else:
                on_progress(
                    f"  [{p.name}] Artist: {artist.name} [{artist.id}]",
                )

            albums = p.artist_albums(artist.id)
            all_albums.extend(_discovery_album_dict(p.name, a) for a in albums)
            on_progress(f"  [{p.name}] {len(albums)} albums")
            provider_album_counts[p.name] = len(albums)
        except Exception as e:
            err = describe_failure(e)
            on_progress(f"  [{p.name}] Discovery failed: {err}")
            provider_errors.append(f"{p.name}: {err}")

    incomplete = bool(provider_errors)
    if not incomplete and provider_album_counts:
        max_count = max(provider_album_counts.values())
        for name, count in provider_album_counts.items():
            if count == 0 and max_count > 0:
                incomplete = True
                provider_errors.append(
                    f"{name}: 0 albums while another provider has {max_count}"
                )

    if incomplete:
        on_progress(
            f"  Curation marked incomplete: {'; '.join(provider_errors)}",
        )

    fetched = len(all_albums)
    all_albums = _dedupe_albums(all_albums)
    if len(all_albums) < fetched:
        on_progress(
            f"  Deduplicated {fetched - len(all_albums)} albums shared "
            f"across artist pages",
        )

    on_progress(
        f"\n  Total: {len(all_albums)} albums across {len(providers)} providers\n"
    )

    return DiscoveryResult(
        all_albums=all_albums,
        artist_ids=artist_ids,
        provider_errors=provider_errors,
        incomplete=incomplete,
    )


async def _run_large(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str,
    api_key: str,
    timeout: int,
    existing_curation: dict | None = None,
    content_type: str = "hoerspiel",
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_facts: SeriesFacts | None = None,
    series_id: str | None = None,
    on_progress: Progress = _noop,
) -> CuratedSeries:
    model = build_model(model_name, api_key)

    discovery = await _run_discovery(
        query,
        providers,
        known_artist_ids=known_artist_ids,
        on_progress=on_progress,
    )
    all_albums = discovery.all_albums
    artist_ids = discovery.artist_ids
    provider_errors = discovery.provider_errors
    incomplete = discovery.incomplete

    # The catalog knows which other entries live on these artist pages;
    # the batch prompt states them so sibling albums are not guessed at.
    sibling_titles = sibling_series(series_id, artist_ids, load_catalog())
    if sibling_titles:
        on_progress(
            f"  Sibling entries on these artist pages: {', '.join(sibling_titles)}\n"
        )

    # -- Step 2a: Pre-fetch full album details
    on_progress("  Pre-fetching album details...")
    prefetch_details: dict[str, dict] = {}
    for a in all_albums:
        provider = next((p for p in providers if p.name == a["provider"]), None)
        if not provider:
            continue
        key = f"{a['provider']}:{a['id']}"
        if key in prefetch_details:
            continue
        detail = provider.album_details(a["id"])
        if detail:
            prefetch_details[key] = album_to_dict(detail)
    on_progress(f"  -> {len(prefetch_details)} albums with full metadata\n")

    # -- Step 2: Metadata extraction
    t_overall = time.monotonic()
    t0 = time.monotonic()
    on_progress("== Metadata ==\n")

    all_titles = [a["name"] for a in all_albums]
    years = []
    for a in all_albums:
        rd = a.get("release_date")
        if rd and len(str(rd)) >= 4 and str(rd)[:4].isdigit():
            years.append(int(str(rd)[:4]))
    discography_span_years = (max(years) - min(years)) if len(years) >= 2 else None

    sample_albums = _stratified_sample(all_albums, 40)
    provider_list = ", ".join(f"{k}: {v}" for k, v in artist_ids.items())

    metadata_agent = _build_metadata_agent(
        model,
        model_name=model_name,
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    meta_deps = CurateDeps(
        providers=providers,
        titles=all_titles,
        on_progress=on_progress,
    )
    sample_lines = "\n".join(
        f"  - {a['name']} | {a['total_tracks']} tracks | {a.get('release_date') or '?'}"
        for a in sample_albums
    )
    meta = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(
                metadata_agent,
                f"Series: {query!r}\nProviders: {provider_list}\n"
                f"Sample albums (title | tracks | release_date):\n"
                f"{sample_lines}",
                deps=meta_deps,
            ),
            timeout=timeout,
        ),
        phase="metadata",
        on_progress=on_progress,
    )

    # Discovery artist IDs are the ground truth. The metadata model no
    # longer has access to provider_artist_ids so it cannot override
    # them; if we later need to add an id discovered by the model, it
    # must go through a tool gated by provider.artist_exists().
    provider_artist_ids: dict[str, list[str]] = artist_ids

    on_progress(
        f"  id={meta.id}  title={meta.title!r}  "
        f"pattern={meta.episode_pattern}  age={meta.age_note}\n",
    )
    on_progress(f"  ({_fmt_elapsed(time.monotonic() - t0)})\n")

    # -- Step 3: Batched curation
    all_discovered = all_albums  # full list for cover cache
    all_decisions, all_albums = _preseed_decisions(all_albums, existing_curation)
    future_decisions, all_albums = _pre_decide_future_releases(all_albums)
    if future_decisions:
        all_decisions.extend(future_decisions)
        on_progress(
            f"  Pre-excluded {len(future_decisions)} not-yet-released album(s)."
        )
    total_inc = sum(1 for d in all_decisions if d.include)
    total_exc = sum(1 for d in all_decisions if not d.include)
    episode_nums: list[int] = [
        d.episode_num for d in all_decisions if d.include and d.episode_num is not None
    ]
    if all_decisions:
        on_progress(
            f"  Carried forward {len(all_decisions)} decisions from "
            f"prior run ({total_inc} included, {total_exc} excluded). "
            f"{len(all_albums)} albums remaining.\n",
        )

    batches = [
        all_albums[i : i + _BATCH_SIZE] for i in range(0, len(all_albums), _BATCH_SIZE)
    ]

    orphan_ids: list[str] = []
    t_curation = time.monotonic()
    on_progress(
        f"== Curation == {len(all_albums)} albums in "
        f"{len(batches)} batches of <={_BATCH_SIZE}\n",
    )

    if not all_albums:
        on_progress("  All albums already decided, skipping batches.\n")
    batch_agent = _build_batch_agent(
        model,
        model_name=model_name,
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    shared_deps = CurateDeps(
        providers=providers,
        pattern=meta.episode_pattern,
        titles=all_titles,
        seen_details=prefetch_details,
        on_progress=on_progress,
        usage=meta_deps.usage,
    )

    for batch_num, batch in enumerate(batches, 1):
        if episode_nums:
            progress_text = (
                f"Progress: {total_inc} included (episodes "
                f"{min(episode_nums)}-{max(episode_nums)}), "
                f"{total_exc} excluded."
            )
        else:
            progress_text = f"Progress: {total_inc} included, {total_exc} excluded."

        rolling = _build_batch_summary(
            all_decisions,
            shared_deps.pattern,
            batch_num,
        )

        batch_albums = format_batch_albums(batch, shared_deps.seen_details)

        structural_hints: list[str] = []
        if all_decisions:
            partial = curation_from_decisions(all_decisions, shared_deps.pattern)
            analysis = analyze_series(partial)
            structural_hints = build_structural_hints(analysis)

        albums_xml = format_albums_xml(batch_albums, include_tracks=True)
        prompt = build_batch_prompt(
            series_title=meta.title,
            pattern=shared_deps.pattern,
            progress_text=progress_text,
            rolling=rolling,
            structural_hints=structural_hints,
            sibling_titles=sibling_titles,
            batch_num=batch_num,
            n_batches=len(batches),
            n_albums=len(batch),
            albums_xml=albums_xml,
        )

        shared_deps.current_batch_ids = {(a["provider"], a["id"]) for a in batch}
        t_batch = time.monotonic()
        try:
            result: BatchResult = await run_with_attempts(
                lambda p=prompt: _run_with_retry(
                    lambda: asyncio.wait_for(
                        _run_agent(batch_agent, p, shared_deps),
                        timeout=timeout,
                    ),
                    phase=f"batch {batch_num}/{len(batches)}",
                    on_progress=on_progress,
                ),
                attempts=_BATCH_ATTEMPTS,
                label=f"Batch {batch_num}/{len(batches)}",
                on_progress=on_progress,
                on_failure=lambda _attempt, exc, messages: dump_batch_failure(
                    meta.id,
                    batch_num,
                    prompt,
                    messages,
                    exc,
                ),
            )
        except Exception as exc:
            # A lost batch means the albums in it stay undecided. The run
            # comes out incomplete, which blocks apply; the next run
            # re-queues them through the batch loop.
            on_progress(f"  Saving {len(all_decisions)} partial results.\n")
            incomplete = True
            provider_errors.append(
                f"batch {batch_num}/{len(batches)}: {describe_failure(exc)}"
            )
            break

        result.albums, dropped = drop_orphan_decisions(
            result.albums, shared_deps.current_batch_ids, on_progress
        )
        orphan_ids.extend(dropped)
        batch_index = {(a["provider"], a["id"]): a for a in batch}
        for a in result.albums:
            src = batch_index.get((a.provider, a.album_id))
            if src and not a.release_date:
                a.release_date = src.get("release_date") or None

        n_inc = sum(1 for a in result.albums if a.include)
        n_exc = sum(1 for a in result.albums if not a.include)
        total_inc += n_inc
        total_exc += n_exc
        for a in result.albums:
            if a.include and a.episode_num is not None:
                episode_nums.append(a.episode_num)

        batch_elapsed = _fmt_elapsed(time.monotonic() - t_batch)
        on_progress(
            f"  Batch {batch_num}/{len(batches)}: "
            f"+{n_inc} -{n_exc}  "
            f"(total: {total_inc} included, {total_exc} excluded) "
            f"[{batch_elapsed}]",
        )

        all_decisions.extend(result.albums)

    curation_elapsed = _fmt_elapsed(time.monotonic() - t_curation)
    on_progress(
        f"\n  Total: {total_inc} included  "
        f"{total_exc} excluded  [{curation_elapsed}]\n",
    )

    final_pattern = shared_deps.pattern
    if shared_deps.pattern_revisions and final_pattern is not None:
        on_progress(
            f"  Pattern revised mid-run: {meta.episode_pattern!r} "
            f"-> {final_pattern!r}\n",
        )

    batch_index = {(a["provider"], a["id"]): a for a in all_albums}

    # Undecided albums (dropped by the model or lost to a failed batch)
    # are left absent. They make the run incomplete, which blocks apply.
    # On the next run _preseed_decisions carries forward whatever was
    # decided and re-queues the rest naturally.

    # Always run deterministic episode extraction on the decided albums.
    if final_pattern is not None:
        re_extracted = _reextract_episode_numbers(all_decisions, final_pattern)
        if re_extracted:
            on_progress(
                f"  Deterministic extraction set {re_extracted} episode "
                f"numbers from pattern.\n",
            )

    # -- Finalize metadata: facts discovery + episode extraction
    t_finalize = time.monotonic()
    final_pattern = shared_deps.pattern
    proposed_facts: SeriesFacts | None = None
    if content_type not in ("music", "audiobook"):
        unnumbered = [d for d in all_decisions if d.include and d.episode_num is None]

        era_evidence_lines: list[str] = []
        n_existing_eras = len(existing_facts.era_boundaries)
        era_decisions = [
            d
            for d in all_decisions
            if d.include and d.notes and "era" in d.notes.lower()
        ]
        # Only include era evidence when no era_boundaries exist yet.
        # When eras are already documented, the agent wastes 20-30 tool
        # calls re-investigating collisions it can't resolve. The
        # existing eras are shown in the facts section; the agent can
        # still propose genuinely new eras if it discovers them.
        if era_decisions and not n_existing_eras:
            by_provider: dict[str, list[tuple[int, str, str]]] = {}
            for d in era_decisions:
                ep = d.episode_num
                if ep is None:
                    continue
                by_provider.setdefault(d.provider, []).append(
                    (ep, d.title, d.release_date or "?"),
                )
            era_evidence_lines.append(
                "### Batch-phase era evidence (consider before proposing facts)",
            )
            era_evidence_lines.append(
                "The batch phase flagged the following albums as era "
                "collisions (same episode number, different title / "
                "release date). Group them into distinct eras by "
                "release_date and title pattern, then propose era_boundary "
                "facts. Look for ~3 distinct clusters (e.g. 1977 classics, "
                "2015 CGI reboot, 2025 continuation)."
            )
            for prov, items in sorted(by_provider.items()):
                items.sort(key=lambda x: x[0])
                era_evidence_lines.append(f"  {prov} ({len(items)} albums):")
                for ep, title, date in items:
                    era_evidence_lines.append(f"    ep {ep} | {date} | {title}")
            era_evidence_lines.append("")

        analysis_lines: list[str] = []
        if all_decisions:
            partial_curation = curation_from_decisions(
                all_decisions, shared_deps.pattern
            )
            analysis = analyze_series(partial_curation)
            if analysis.get("gaps"):
                analysis_lines.append(
                    f"Gaps: {len(analysis['gaps'])} missing episodes "
                    f"({analysis['gaps']})"
                )
            dupes = analysis.get("duplicates_within_provider") or []
            if dupes:
                by_prov: dict[str, list[int]] = {}
                for d in dupes:
                    by_prov.setdefault(d["provider"], []).append(d["episode_num"])
                for prov, eps in by_prov.items():
                    analysis_lines.append(
                        f"Duplicates on {prov}: episodes {sorted(eps)}"
                    )
            xpc = analysis.get("cross_provider_coverage") or {}
            missing_per = xpc.get("missing_per_provider") or {}
            for prov, missing_eps in missing_per.items():
                if missing_eps:
                    analysis_lines.append(f"{prov} missing: {missing_eps}")
            if analysis.get("outliers"):
                analysis_lines.append(
                    f"Outlier title shapes: {len(analysis['outliers'])}"
                )
            pc = analysis.get("pattern_coverage")
            if isinstance(pc, dict):
                analysis_lines.append(f"Pattern coverage: {pc['percentage']}%")

        sub_bleed_titles: list[str] = []
        seen_titles: set[str] = set()
        for d in all_decisions:
            if d.include or d.exclude_reason != "sub_series_bleed":
                continue
            if d.title in seen_titles:
                continue
            seen_titles.add(d.title)
            sub_bleed_titles.append(d.title)
        has_sub_bleed = bool(sub_bleed_titles)
        if has_sub_bleed:
            analysis_lines.append(
                f"Sub-series exclusions: {len(sub_bleed_titles)} unique "
                f"titles excluded as sub_series_bleed or sub_series."
            )

        needs_finalize = bool(unnumbered) or bool(era_evidence_lines) or has_sub_bleed
        if needs_finalize:
            _MAX_INLINE_TRACKS = 3
            lines: list[str] = []
            for d in unnumbered:
                key = f"{d.provider}:{d.album_id}"
                detail = shared_deps.seen_details.get(key)
                tracks = ""
                if detail and detail.get("tracks"):
                    track_names = [t["name"] for t in detail["tracks"]]
                    shown = track_names[:_MAX_INLINE_TRACKS]
                    if len(track_names) > _MAX_INLINE_TRACKS:
                        shown.append(
                            f"... +{len(track_names) - _MAX_INLINE_TRACKS} more"
                        )
                    tracks = " | tracks: " + " | ".join(shown)
                lines.append(f"  {d.provider}:{d.album_id} | {d.title}{tracks}")
            facts_lines: list[str] = []
            if existing_facts:
                if existing_facts.era_boundaries:
                    facts_lines.append("Existing era_boundaries:")
                    for e in existing_facts.era_boundaries:
                        facts_lines.append(f"  - {e.label}: {e.release_date_range}")
                if existing_facts.known_gaps:
                    facts_lines.append("Existing known_gaps:")
                    for g in existing_facts.known_gaps:
                        label = (
                            f"{g.number}-{g.range_end}"
                            if g.range_end
                            else str(g.number)
                        )
                        facts_lines.append(f"  - Episode {label}: {g.reason}")
                if existing_facts.sub_series:
                    facts_lines.append("Existing sub_series:")
                    for s in existing_facts.sub_series:
                        facts_lines.append(f"  - {s.label}: {s.reason}")
                if not facts_lines:
                    facts_lines.append("Existing facts: (none)")
            else:
                facts_lines.append("Existing facts: (none)")

            header_parts: list[str] = []
            if unnumbered:
                header_parts.append(
                    f"{len(unnumbered)} included albums lack episode numbers"
                )
            if era_evidence_lines:
                header_parts.append("era evidence found")
            if has_sub_bleed:
                header_parts.append(
                    f"{len(sub_bleed_titles)} sub-series exclusions to evaluate for splits"
                )
            header = (
                f"== Finalize == {' AND '.join(header_parts)}. "
                f"Inspecting track listings and proposing facts...\n"
            )
            on_progress(header)

            finalize_agent = _build_finalize_agent(
                model,
                model_name=model_name,
                content_type=content_type,
                discography_span_years=discography_span_years,
            )

            # Build a concise work-item summary so the agent
            # knows exactly what to focus on.
            work_items: list[str] = []
            if unnumbered:
                work_items.append(
                    f"- {len(unnumbered)} unnumbered album(s): "
                    f"check track listings for episode numbers"
                )
            if era_evidence_lines:
                work_items.append(
                    "- Era evidence: propose era_boundaries from flagged albums"
                )
            elif era_decisions and n_existing_eras:
                work_items.append(
                    f"- Era: {n_existing_eras} era_boundaries already "
                    f"documented, skip Step 2"
                )
            if has_sub_bleed:
                work_items.append(
                    f"- Sub-series: {len(sub_bleed_titles)} unique titles "
                    f"excluded as sub_series_bleed/sub_series. "
                    f"Use search_excluded_albums to explore and propose "
                    f"sub_series facts."
                )

            prompt_parts: list[str] = [
                f"Series: {meta.title!r}",
                f"Episode pattern: {shared_deps.pattern}",
            ]
            if work_items:
                prompt_parts.append("## Work items\n" + "\n".join(work_items))
            prompt_parts.extend(
                [
                    "",
                    "\n".join(facts_lines),
                    "",
                    "\n".join(era_evidence_lines),
                ]
            )
            if analysis_lines:
                prompt_parts.append(
                    "### Structural analysis (deterministic)\n"
                    + "\n".join(analysis_lines)
                )
            if unnumbered:
                prompt_parts.append(
                    f"Included albums missing episode numbers ({len(unnumbered)} total):\n"
                    f"\n".join(lines)
                )
            finalize_prompt = "\n".join(prompt_parts)
            finalize_deps = CurateDeps(
                providers=providers,
                seen_details=shared_deps.seen_details,
                pattern=shared_deps.pattern,
                titles=all_titles,
                existing_facts=existing_facts,
                all_decisions=all_decisions,
                on_progress=on_progress,
                usage=shared_deps.usage,
            )
            try:
                finalize_result: FinalizeResult = await _run_with_retry(
                    lambda: asyncio.wait_for(
                        _run_agent(
                            finalize_agent,
                            finalize_prompt,
                            finalize_deps,
                        ),
                        timeout=timeout,
                    ),
                    phase="finalize",
                    on_progress=on_progress,
                )
                updated = 0
                for upd in finalize_result.episode_updates:
                    for d in all_decisions:
                        if d.album_id == upd.album_id and d.provider == upd.provider:
                            d.episode_num = upd.episode_num
                            updated += 1
                            break
                if updated:
                    on_progress(
                        f"  Finalize set {updated} episode numbers from "
                        f"track listings.\n",
                    )
                # Pattern updates are side effects of the
                # propose_pattern_update tool; the output field is gone.
                if finalize_deps.pattern != shared_deps.pattern:
                    shared_deps.pattern = finalize_deps.pattern
                    shared_deps.pattern_revisions.append(finalize_deps.pattern)
                    on_progress(
                        f"  Finalize proposed pattern update -> "
                        f"{finalize_deps.pattern}\n",
                    )
                proposed_facts = finalize_deps.proposed_facts
                if proposed_facts:
                    n_new = (
                        len(proposed_facts.era_boundaries)
                        + len(proposed_facts.known_gaps)
                        + len(proposed_facts.sub_series)
                    )
                    if n_new:
                        on_progress(
                            f"  Finalize proposed {n_new} new fact(s)\n",
                        )
            except Exception as exc:
                incomplete = True
                err = describe_failure(exc)
                provider_errors.append(f"finalize: {err}")
                on_progress(
                    f"  Finalize phase failed: {err}. "
                    f"Proceeding with batch results (marked incomplete).\n",
                )

        final_pattern = shared_deps.pattern
        if shared_deps.pattern_revisions and final_pattern is not None:
            re_extracted = _reextract_episode_numbers(all_decisions, final_pattern)
            if re_extracted:
                on_progress(
                    f"  Pattern revised: {meta.episode_pattern!r} "
                    f"-> {final_pattern!r}. Re-extracted {re_extracted} episode "
                    f"numbers across all batches.\n",
                )

    # Merge existing + proposed facts, deduped by natural key.
    merged_facts = merge_facts(existing_facts, proposed_facts)

    # With the eras known, same-provider duplicates are settled by fact.
    eras = merged_facts.era_boundaries if merged_facts else []
    before = sum(1 for d in all_decisions if d.include)
    all_decisions = _settle_same_provider_duplicates(all_decisions, eras)
    total_inc = sum(1 for d in all_decisions if d.include)
    total_exc = len(all_decisions) - total_inc
    if total_inc < before:
        on_progress(
            f"  Settled {before - total_inc} same-provider duplicate(s) by era fact.\n"
        )

    on_progress(f"  Finalize: {_fmt_elapsed(time.monotonic() - t_finalize)}\n")

    overall = _fmt_elapsed(time.monotonic() - t_overall)
    on_progress(
        f"\n== Done == {total_inc} included, {total_exc} excluded [{overall}] "
        f"{shared_deps.usage.requests} requests, "
        f"{shared_deps.usage.input_tokens} in / "
        f"{shared_deps.usage.output_tokens} out tokens\n"
    )

    write_cover_cache(meta.id, all_discovered)

    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        episode_pattern=final_pattern,
        albums=all_decisions,
        provider_artist_ids=provider_artist_ids,
        age_note=meta.age_note,
        curator_notes=meta.curator_notes,
        series_facts=merged_facts or SeriesFacts(),
        incomplete=incomplete,
        incomplete_reason="; ".join(provider_errors) if incomplete else "",
        curated_by=model_name,
        usage=usage_summary(shared_deps.usage),
        orphan_ids=orphan_ids,
    )


# ── Save / display ────────────────────────────────────────────────────────


def write_cover_cache(series_id: str, albums: list[dict]) -> None:
    """Write album_id -> image_url mapping to the gitignored cover cache.

    Accepts the raw album dicts from discovery (key: "id") or curation
    JSON (key: "album_id"). Skips albums without an image_url.
    """
    covers = {}
    for a in albums:
        album_id = a.get("album_id") or a.get("id")
        url = a.get("image_url", "")
        if album_id and url:
            covers[album_id] = url
    if not covers:
        return
    cache = cover_cache_dir()
    cache.mkdir(parents=True, exist_ok=True)
    safe_write_json(cover_cache_path(series_id), covers)


def save_curation(
    series: CuratedSeries,
    on_progress: Progress = _noop,
) -> Path:
    """Persist curate's findings into the curation JSON.

    Reads the existing file (if any) and overwrites only curate-owned
    fields. Anything we don't touch (review/audit block, future fields)
    is naturally preserved.

    Raises ValueError if the existing file is corrupt.
    """
    path = curation_path(series.id)
    path.parent.mkdir(parents=True, exist_ok=True)

    data: dict = {}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(
                f"Refusing to overwrite unreadable curation file: {path}. "
                f"Error: {type(exc).__name__}: {exc}. "
                f"This file may contain approved audit state. "
                f"Inspect it before re-curating."
            ) from exc

    old_albums = data.get("albums", [])
    new_album_ids = {a.album_id for a in series.albums}
    old_album_ids = {a.get("album_id") for a in old_albums if a.get("album_id")}
    if old_album_ids and new_album_ids != old_album_ids:
        on_progress(
            f"  Album set changed ({len(old_album_ids)} -> {len(new_album_ids)})."
        )

    # Any re-curation invalidates the prior audit: the agent may have
    # changed include/exclude decisions, episode numbers, or facts even
    # when the album ID set is identical. Clearing forces re-audit.
    data.pop("review", None)

    data.update(
        {
            "id": series.id,
            "title": series.title,
            "content_type": series.content_type,
            "aliases": series.aliases,
            "episode_pattern": series.episode_pattern,
            "provider_artist_ids": series.provider_artist_ids,
            "age_note": series.age_note,
            "curator_notes": series.curator_notes,
            "series_facts": series.series_facts.model_dump(),
            "regression_flags": series.regression_flags,
            "curated_at": datetime.now(UTC).isoformat(),
            "albums": [a.model_dump() for a in series.albums],
            "incomplete": series.incomplete,
            "incomplete_reason": series.incomplete_reason,
            "curated_by": series.curated_by,
            "usage": series.usage,
            "orphan_ids": series.orphan_ids,
        }
    )

    canonicalize(data)
    safe_write_json(path, data)
    return path


# ── Utility functions ─────────────────────────────────────────────────────


def resolve_content_type(
    entry_content_type: str | None,
    entry_has_pattern: bool,
    existing_content_type: str | None,
) -> Literal["hoerspiel", "music", "audiobook"]:
    """Decide the content_type for curation.

    series.yaml is canonical: an explicit content_type there wins.
    """
    if entry_content_type in ("hoerspiel", "music", "audiobook"):
        return entry_content_type  # type: ignore[return-value]
    if entry_content_type is not None:
        raise ValueError(
            f"unknown content_type {entry_content_type!r} in series.yaml. "
            f"Use one of: hoerspiel, music, audiobook.",
        )
    if entry_has_pattern:
        return "hoerspiel"
    if existing_content_type in ("hoerspiel", "music", "audiobook"):
        return existing_content_type  # type: ignore[return-value]
    if existing_content_type is not None:
        raise ValueError(
            f"unknown content_type {existing_content_type!r} in existing "
            f"curation. Use one of: hoerspiel, music, audiobook.",
        )
    return "hoerspiel"


def load_existing_facts(entry) -> SeriesFacts:
    """Load frozen facts from a CatalogEntry, if any."""
    if entry.series_facts:
        return SeriesFacts.model_validate(entry.series_facts)
    return SeriesFacts()


def lock_series_id(
    series: CuratedSeries,
    canonical_id: str | None,
    on_progress: Progress = _noop,
) -> CuratedSeries:
    """Force ``series.id`` to the canonical value when one is known."""
    if canonical_id and series.id != canonical_id:
        on_progress(
            f"  Locked id to canonical: {series.id!r} -> "
            f"{canonical_id!r} (model output overridden by series.yaml)",
        )
        series.id = canonical_id
    return series


# ── Top-level library functions ───────────────────────────────────────────


@dataclass
class CurateOneResult:
    """Result of curating a single series."""

    ok: bool = True
    series: CuratedSeries | None = None
    path: Path | None = None
    error: str | None = None


@dataclass
class CurateAllResult:
    """Result of curating all series in the catalog."""

    total: int = 0
    succeeded: int = 0
    skipped: int = 0
    failed: int = 0
    failed_ids: list[str] = field(default_factory=list)


@dataclass
class CurateEntryPrepared:
    """Everything curate_one needs, resolved from the catalog entry.

    One place decides how the prior curation, the yaml content type,
    split protection, and the canonical id interact.
    """

    entry: CatalogEntry
    requested_type: str
    entry_content_type: str = "hoerspiel"
    existing: dict | None = None

    @property
    def series_id(self) -> str:
        return self.entry.id


def prepare_curation(
    entry_or_query: CatalogEntry | str,
    *,
    cli_content_type: str | None = None,
) -> CurateEntryPrepared:
    """Resolve everything an entry-level curation run needs.

    Loads the entry from the catalog when given only a query string,
    refuses split-off children, loads the prior curation record, and
    resolves the content type (CLI override > series.yaml > inference).
    """
    if isinstance(entry_or_query, CatalogEntry):
        entry: CatalogEntry = entry_or_query
    else:
        found = lookup_catalog_entry(entry_or_query)
        if found is None:
            raise KeyError(f"series {entry_or_query!r} not in the catalog")
        entry = found

    if entry.split_from:
        raise ValueError(split_off_refusal(entry.id, entry.split_from))

    existing: dict | None = None
    if curation_path(entry.id).exists():
        try:
            existing = load_curation(entry.id)
        except (OSError, ValueError) as exc:
            raise ValueError(
                f"prior curation for {entry.id} is unreadable "
                f"({type(exc).__name__}: {exc}); inspect it before "
                f"re-curating, it may hold approved audit state"
            ) from exc

    entry_content_type = resolve_content_type(
        entry_content_type=entry.content_type,
        entry_has_pattern=bool(entry.episode_pattern),
        existing_content_type=(existing or {}).get("content_type"),
    )
    requested = cli_content_type or entry_content_type
    return CurateEntryPrepared(
        entry=entry,
        existing=existing,
        requested_type=requested,
        entry_content_type=entry_content_type,
    )


async def curate_entry(
    prepared: CurateEntryPrepared,
    providers: list[CatalogProvider],
    *,
    model: str = _DEFAULT_MODEL,
    timeout: int = 3600,
    on_progress: Progress = _noop,
) -> CurateOneResult:
    """Curate one catalog entry end to end, from a prepared context.

    The single path the CLI, the web job runner, and curate --all use:
    one place decides content type, the canonical id, known artist
    ids, and the frozen-facts merge.
    """
    return await curate_one(
        prepared.entry.title,
        providers,
        model=model,
        timeout=timeout,
        series_id=prepared.series_id,
        known_artist_ids=prepared.entry.all_artist_ids() or None,
        existing_curation=prepared.existing,
        content_type=prepared.requested_type,
        existing_facts=load_existing_facts(prepared.entry),
        on_progress=on_progress,
    )


async def curate_one(
    query: str,
    providers: list[CatalogProvider],
    *,
    model: str = _DEFAULT_MODEL,
    timeout: int = 3600,
    series_id: str | None = None,
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_curation: dict | None = None,
    content_type: str = "hoerspiel",
    existing_facts: SeriesFacts | None = None,
    on_progress: Progress = _noop,
) -> CurateOneResult:
    """Curate a single series (non-interactive).

    Runs the AI curation pipeline: discovery, metadata extraction,
    batched album decisions, finalization. Writes the curation JSON
    and cover cache.
    """
    try:
        if content_type == "music":
            on_progress("  Mode: music artist (not Hoerspiel)")
        existing_curation = _inject_split_children(
            existing_curation,
            series_id,
        )
        # Carry facts from the prior curation JSON forward, not just the
        # frozen series.yaml facts: re-curation is an incremental update,
        # not a rediscovery from scratch. series.yaml wins on conflict.
        existing_facts = merge_facts(
            existing_facts,
            facts_from_curation(existing_curation),
        )
        api_key = os.environ.get("OPENCODE_API_KEY", "")
        if not api_key:
            raise ValueError("OPENCODE_API_KEY not set")
        series = await _run_large(
            query,
            providers,
            model_name=model,
            api_key=api_key,
            timeout=timeout,
            existing_curation=existing_curation,
            content_type=content_type,
            known_artist_ids=known_artist_ids,
            existing_facts=existing_facts,
            on_progress=on_progress,
            series_id=series_id,
        )
        series.content_type = content_type
        lock_series_id(series, series_id, on_progress=on_progress)
        series.regression_flags = lint_regression(
            existing_curation,
            {
                "albums": [a.model_dump() for a in series.albums],
                "series_facts": series.series_facts.model_dump(),
            },
        )
        for flag in series.regression_flags:
            on_progress(f"  [regression] {flag}")
        path = save_curation(series, on_progress=on_progress)
        on_progress(f"Saved to {path}")
        record_event(
            RunEvent(
                series_id=series.id,
                phase="curate",
                outcome=OUTCOME_OK,
                detail=f"{len(series.included())} included / "
                f"{len(series.albums) - len(series.included())} excluded"
                + (" [incomplete run]" if series.incomplete else ""),
                usage=series.usage,
                evidence=str(path),
            )
        )
        return CurateOneResult(ok=True, series=series, path=path)
    except Exception as e:
        import traceback

        msg = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
        on_progress(f"Failed to curate {query}: {msg}")
        on_progress(traceback.format_exc())
        record_event(
            RunEvent(
                series_id=series_id or title_to_id(query),
                phase="curate",
                outcome=OUTCOME_FAILED,
                detail=msg,
            )
        )
        return CurateOneResult(ok=False, error=msg)


async def curate_all(
    providers: list[CatalogProvider],
    *,
    model: str = _DEFAULT_MODEL,
    timeout: int = 3600,
    force: bool = False,
    on_progress: Progress = _noop,
    concurrency: int = 1,
) -> CurateAllResult:
    """Curate all series in the catalog.

    ``concurrency`` series may run at once; 2 overlaps two model waits
    without leaning on unknown relay limits. Each result lands in its
    own curation JSON and run event, so interleaved progress is the
    only observable difference.
    """
    entries = load_catalog()
    total = len(entries)
    result = CurateAllResult(total=total)

    on_progress(
        f"Curating {total} series with {model}\n"
        f"Providers: {', '.join(p.name for p in providers)}\n"
        f"Force: {force}"
    )

    # Filter the cheap skips first: split-offs and already-curated
    # entries never touch the model, so they stay in this sync pass.
    todo: list[tuple[int, CurateEntryPrepared]] = []
    for i, entry in enumerate(entries):
        if entry.split_from:
            result.skipped += 1
            refusal = split_off_refusal(entry.id, entry.split_from)
            on_progress(f"  Skipped: {refusal}")
            record_event(
                RunEvent(
                    series_id=entry.id,
                    phase="curate",
                    outcome=OUTCOME_SKIPPED,
                    detail=refusal,
                )
            )
            continue
        if curation_path(entry.id).exists() and not force:
            result.skipped += 1
            record_event(
                RunEvent(
                    series_id=entry.id,
                    phase="curate",
                    outcome=OUTCOME_SKIPPED,
                    detail="curation exists (no --force)",
                )
            )
            continue
        try:
            todo.append((i, prepare_curation(entry)))
        except (OSError, ValueError) as exc:
            result.failed += 1
            result.failed_ids.append(entry.id)
            on_progress(f"  Failed to prepare {entry.id}: {exc}")
            record_event(
                RunEvent(
                    series_id=entry.id,
                    phase="curate",
                    outcome=OUTCOME_FAILED,
                    detail=str(exc),
                )
            )
            continue

    async def run_one(item: tuple[int, CurateEntryPrepared]) -> None:
        i, prepared = item
        on_progress(
            f"\n[{prepared.series_id}] ({i + 1}/{total}) {prepared.entry.title} "
            f"({result.succeeded} done, {result.failed} failed, "
            f"{result.skipped} skipped)",
        )
        one_result = await curate_entry(
            prepared,
            providers,
            model=model,
            timeout=timeout,
            on_progress=on_progress,
        )
        if one_result.ok:
            result.succeeded += 1
        else:
            result.failed += 1
            result.failed_ids.append(prepared.series_id)

    await run_bounded(run_one, todo, concurrency=concurrency)

    on_progress(
        f"\nResults: {result.succeeded} curated, "
        f"{result.skipped} skipped, {result.failed} failed",
    )
    if result.failed_ids:
        on_progress(f"Failed: {', '.join(result.failed_ids)}")

    return result
