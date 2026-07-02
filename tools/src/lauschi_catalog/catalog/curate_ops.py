"""Library functions for AI-assisted series curation.

Pydantic models, agent builders, async orchestration, and persistence.
Interactive prompts and Rich display stay in the CLI layer
(commands/curate.py). Progress is reported via callbacks so both CLI
and web UI can consume it.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_ai import Agent, ModelRetry, RunContext

from lauschi_catalog._opencode import (
    build_model,
    get_model_settings,
)
from lauschi_catalog.agent_deps import AgentDeps, Progress, _noop
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.catalog.analysis import analyze_series
from lauschi_catalog.catalog.canonical import canonicalize
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
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.matcher import (
    compute_pattern_coverage as _compute_pattern_coverage,
    extract_episode,
)
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import (
    CURATION_DIR,
    cover_cache_dir,
    cover_cache_path,
)
from lauschi_catalog.catalog.prompt import album_to_dict, format_albums_xml
from lauschi_catalog.agent_hooks import build_progress_hooks
from lauschi_catalog.catalog.lint_ops import lint_curation, lint_regression
from lauschi_catalog.prompts import load_curate_skill
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.rate_limit import RateLimiter, run_with_rate_limit_retry
from lauschi_catalog.run import run_agent

_DEFAULT_MODEL = "kimi-k2.6"

_BATCH_SIZE = 30


class DiscoveryRegressionError(Exception):
    """Raised when a provider API returns dramatically fewer albums than
    the previous curation, indicating an incomplete API response rather
    than genuine catalog changes."""


def _check_discovery_regression(
    all_albums: list[dict],
    existing_curation: dict | None,
    *,
    min_prev_count: int = 20,
    max_drop_ratio: float = 0.5,
) -> list[str]:
    """Compare per-provider album counts against a previous curation.

    Returns a list of regression messages (empty = no regression).
    Each message describes a provider whose discovered album count
    dropped below the threshold relative to the previous curation.
    """
    if not existing_curation or not existing_curation.get("albums"):
        return []

    prev_by_prov: dict[str, int] = {}
    for a in existing_curation["albums"]:
        prov = a.get("provider", "")
        prev_by_prov[prov] = prev_by_prov.get(prov, 0) + 1

    cur_by_prov: dict[str, int] = {}
    for a in all_albums:
        prov = a.get("provider", "")
        cur_by_prov[prov] = cur_by_prov.get(prov, 0) + 1

    regressions: list[str] = []
    for prov, prev_count in prev_by_prov.items():
        cur_count = cur_by_prov.get(prov, 0)
        if prev_count >= min_prev_count and cur_count < prev_count * max_drop_ratio:
            regressions.append(
                f"{prov} discovery collapsed: {prev_count} albums in "
                f"previous curation, only {cur_count} returned now"
            )
    return regressions


# ── Pure helpers ──────────────────────────────────────────────────────────


def _validate_episode_pattern(v: str | list[str] | None) -> str | list[str] | None:
    """Validate that an episode_pattern has at least one capture group."""
    if v is None:
        return None
    patterns = [v] if isinstance(v, str) else v
    for p in patterns:
        c = re.compile(p)
        if c.groups < 1:
            msg = f"Pattern {p!r}: needs at least 1 capture group"
            raise ValueError(msg)
    return v


def _build_batch_summary(
    decisions: list[AlbumDecision],
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
                # Compress consecutive runs: 1,2,3,5,6 -> 1-3, 5-6
                runs: list[str] = []
                start = prev = eps[0]
                for e in eps[1:]:
                    if e == prev + 1:
                        prev = e
                    else:
                        runs.append(f"{start}-{prev}" if prev > start else str(start))
                        start = prev = e
                runs.append(f"{start}-{prev}" if prev > start else str(start))
                lines.append(f"  {prov}: {', '.join(runs)}")

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


def _preseed_decisions(
    all_albums: list[dict],
    existing_curation: dict | None,
) -> tuple[list[AlbumDecision], list[dict]]:
    """Carry forward decisions from a prior (possibly incomplete) curation.

    Returns (carried_decisions, remaining_albums) where remaining_albums
    is the subset of all_albums not already decided.
    """
    if not existing_curation or not existing_curation.get("albums"):
        return [], all_albums

    discovered_ids = {(a["provider"], a["id"]) for a in all_albums}
    carried: list[AlbumDecision] = []
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
        except Exception:
            continue

    if not carried:
        return [], all_albums

    carried_ids = {(d.provider, d.album_id) for d in carried}
    remaining = [
        a for a in all_albums
        if (a["provider"], a["id"]) not in carried_ids
    ]
    return carried, remaining


def _restore_dropped_albums(
    decisions: list[AlbumDecision],
    album_index: dict[tuple[str, str], dict[str, str]],
    on_progress: Progress = _noop,
) -> None:
    """Add any discovered albums the agent omitted as 'not_decided'.

    Mutates ``decisions`` in place.
    """
    discovered_ids = set(album_index.keys())
    decided_ids = {(d.provider, d.album_id) for d in decisions}
    dropped = discovered_ids - decided_ids
    if not dropped:
        return

    on_progress(
        f"  {len(dropped)} discovered album(s) missing from "
        f"agent output, adding as 'not_decided'",
    )
    for prov, aid in sorted(dropped):
        src = album_index.get((prov, aid))
        decisions.append(
            AlbumDecision(
                album_id=aid,
                provider=prov,
                include=True,
                title=src["name"] if src else "unknown",
                release_date=src.get("release_date") if src else None,
                episode_num=None,
                confidence="low",
                notes="auto-included: agent omitted this album from its output",
            )
        )


def _stratified_sample(items: list, n: int) -> list:
    """Pick ``n`` items spread evenly across ``items`` rather than
    taking the head.

    Provider APIs return albums in some order (Spotify: roughly
    newest-first). Taking the first N can blind the metadata agent
    to era-specific naming conventions.
    """
    if len(items) <= n:
        return list(items)
    step = len(items) / n
    return [items[int(i * step)] for i in range(n)]


def _reextract_episode_numbers(
    decisions: list[AlbumDecision],
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
    "sub_series",
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
    def _notes_required_when_unsure(self) -> AlbumDecision:
        if self.confidence != "high" and not self.notes:
            raise ValueError(
                "confidence != 'high' requires `notes` describing why",
            )
        return self

    @model_validator(mode="after")
    def _exclude_reason_required_when_excluded(self) -> AlbumDecision:
        if not self.include and not self.exclude_reason:
            self.exclude_reason = self.notes or "unspecified"
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
            key=lambda a: (
                a.episode_num is None,
                a.episode_num,
                a.release_date or "",
                a.title,
            ),
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
    provider_artist_ids: dict[str, list[str]] = Field(default_factory=dict)

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        return _validate_episode_pattern(v)


# ── Agent dependencies ────────────────────────────────────────────────────


@dataclass
class CurateDeps(AgentDeps):
    """Dependency container for all curate-phase agents."""

    seen_albums: dict[str, list[dict]] = field(default_factory=dict)
    pattern: str | list[str] | None = None
    pattern_revisions: list[str | list[str]] = field(default_factory=list)
    titles: list[str] = field(default_factory=list)
    existing_facts: SeriesFacts = field(default_factory=SeriesFacts)
    proposed_facts: SeriesFacts | None = field(default=None, init=False)
    all_decisions: list[AlbumDecision] = field(default_factory=list)
    current_batch_ids: set[tuple[str, str]] = field(default_factory=set, init=False)
    _pattern_check_count: int = field(default=0, init=False)
    _MAX_PATTERN_CHECKS: int = 5


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
    proposed_pattern_update: str | list[str] | None = Field(
        default=None,
        description="If track listings reveal a systematic new format not caught by the current pattern, propose an updated regex. Null if no change needed.",
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
        """Every album in the batch must have a decision."""
        if not ctx.deps.current_batch_ids:
            return result
        returned_ids = {(a.provider, a.album_id) for a in result.albums}
        missing = ctx.deps.current_batch_ids - returned_ids
        if missing:
            samples = [f"{p}:{aid}" for p, aid in sorted(missing)[:5]]
            raise ModelRetry(
                f"You omitted {len(missing)} album(s) from your output. "
                f"Every album in the batch needs a decision (include or "
                f"exclude). Missing: {', '.join(samples)}"
                f"{'...' if len(missing) > 5 else ''}",
            )
        return result

    return agent


def _search_included_albums(
    decisions: list[AlbumDecision],
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
        partial_curation = {
            "albums": [
                {
                    "album_id": d.album_id,
                    "provider": d.provider,
                    "include": d.include,
                    "title": d.title,
                    "episode_num": d.episode_num,
                    "release_date": d.release_date,
                    "exclude_reason": d.exclude_reason,
                }
                for d in ctx.deps.all_decisions
            ],
            "episode_pattern": ctx.deps.pattern,
            "series_facts": (
                ctx.deps.proposed_facts.model_dump()
                if ctx.deps.proposed_facts
                else None
            ),
        }
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
            prop_nums = set(range(proposal.number, (proposal.range_end or proposal.number) + 1))
            if prop_nums & all_nums:
                continue
            accumulated.known_gaps.append(
                KnownGap(**proposal.model_dump(), **prov),
            )
            label = f"{proposal.number}-{proposal.range_end}" if proposal.range_end else str(proposal.number)
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
    return await run_agent(agent, prompt, deps, request_limit=200)


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
    model_name: str = "",
    on_progress: Progress = _noop,
):
    rate_limiter = RateLimiter(model_name)
    return await run_with_rate_limit_retry(
        coro_factory,
        phase=phase,
        rate_limiter=rate_limiter,
        max_retries=12,
        base_delay=10.0,
        max_delay=300.0,
        on_progress=on_progress,
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
    on_progress: Progress = _noop,
) -> CuratedSeries:
    model = build_model(model_name, api_key)

    # -- Step 1: Discovery
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
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
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

    # -- Step 1b: Per-provider discovery regression check
    regressions = _check_discovery_regression(all_albums, existing_curation)
    if regressions:
        for msg in regressions:
            on_progress(f"  [REGRESSION] {msg}")
        raise DiscoveryRegressionError(
            "Refusing to curate: provider API returned dramatically "
            "fewer albums than the previous curation. The existing "
            "curation file is preserved.\n"
            + "\n".join(f"  - {r}" for r in regressions)
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
        model_name=model_name,
        on_progress=on_progress,
    )
    if not meta.provider_artist_ids:
        meta.provider_artist_ids = artist_ids

    assert meta is not None

    on_progress(
        f"  id={meta.id}  title={meta.title!r}  "
        f"pattern={meta.episode_pattern}  age={meta.age_note}\n",
    )
    on_progress(f"  ({_fmt_elapsed(time.monotonic() - t0)})\n")

    # -- Step 3: Batched curation
    all_discovered = all_albums  # full list for cover cache
    all_decisions, all_albums = _preseed_decisions(all_albums, existing_curation)
    total_inc = sum(1 for d in all_decisions if d.include)
    total_exc = sum(1 for d in all_decisions if not d.include)
    episode_nums: list[int] = [
        d.episode_num for d in all_decisions
        if d.include and d.episode_num is not None
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

        batch_albums: list[dict] = []
        for a in batch:
            key = f"{a['provider']}:{a['id']}"
            detail = shared_deps.seen_details.get(key)
            if detail:
                batch_albums.append(detail)
            else:
                batch_albums.append(
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
        album_xml = format_albums_xml(batch_albums, include_tracks=True)

        analysis_hint = ""
        if all_decisions:
            partial = {
                "albums": [
                    {
                        "album_id": d.album_id,
                        "provider": d.provider,
                        "include": d.include,
                        "title": d.title,
                        "episode_num": d.episode_num,
                        "release_date": d.release_date,
                    }
                    for d in all_decisions
                ],
                "episode_pattern": shared_deps.pattern,
            }
            analysis = analyze_series(partial)
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
            if clusters:
                for c in clusters:
                    examples = ", ".join(c["examples"][:3])
                    hints.append(
                        f"Title cluster {c['shape']!r} ({c['count']} albums): {examples}"
                    )
            if hints:
                analysis_hint = (
                    "Structural signals from prior batches:\n"
                    + "\n".join(f"  {h}" for h in hints)
                    + "\n"
                )

        prompt = (
            f"Series: {meta.title!r}\n"
            f"Episode pattern: {shared_deps.pattern}\n"
            f"{progress_text}\n"
        )
        if rolling:
            prompt += f"{rolling}\n"
        if analysis_hint:
            prompt += f"{analysis_hint}\n"
        prompt += (
            f"\nBatch {batch_num}/{len(batches)} ({len(batch)} albums):\n\n{album_xml}"
        )

        shared_deps.current_batch_ids = {(a["provider"], a["id"]) for a in batch}
        t_batch = time.monotonic()
        try:
            result: BatchResult = await _run_with_retry(
                lambda p=prompt: asyncio.wait_for(
                    _run_agent(batch_agent, p, shared_deps),
                    timeout=timeout,
                ),
                phase=f"batch {batch_num}/{len(batches)}",
                model_name=model_name,
                on_progress=on_progress,
            )
        except Exception as exc:
            err = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
            on_progress(
                f"  Batch {batch_num}/{len(batches)} failed after retries: "
                f"{err}. Saving {len(all_decisions)} partial results.\n",
            )
            incomplete = True
            provider_errors.append(
                f"batch {batch_num}/{len(batches)}: {err}"
            )
            break

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

        if batch_num < len(batches):
            await asyncio.sleep(4)

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

    # Always run deterministic episode extraction after batches.
    # The batch agent may return episode_num=null even when the title
    # clearly matches the pattern.
    if final_pattern is not None:
        re_extracted = _reextract_episode_numbers(all_decisions, final_pattern)
        if re_extracted:
            on_progress(
                f"  Deterministic extraction set {re_extracted} episode "
                f"numbers from pattern.\n",
            )

    batch_index = {(a["provider"], a["id"]): a for a in all_albums}
    _restore_dropped_albums(all_decisions, batch_index, on_progress=on_progress)

    # -- Finalize metadata: facts discovery + episode extraction
    t_finalize = time.monotonic()
    final_pattern = shared_deps.pattern
    proposed_facts: SeriesFacts | None = None
    if content_type not in ("music", "audiobook"):
        unnumbered = [d for d in all_decisions if d.include and d.episode_num is None]

        era_evidence_lines: list[str] = []
        n_existing_eras = len(
            (existing_facts or SeriesFacts()).era_boundaries
        )
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
            partial_curation = {
                "albums": [
                    {
                        "album_id": d.album_id,
                        "provider": d.provider,
                        "include": d.include,
                        "title": d.title,
                        "episode_num": d.episode_num,
                        "release_date": d.release_date,
                    }
                    for d in all_decisions
                ],
                "episode_pattern": shared_deps.pattern,
            }
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

        needs_finalize = bool(unnumbered) or bool(era_evidence_lines)
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
                        shown.append(f"... +{len(track_names) - _MAX_INLINE_TRACKS} more")
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
                        label = f"{g.number}-{g.range_end}" if g.range_end else str(g.number)
                        facts_lines.append(f"  - Episode {label}: {g.reason}")
                if existing_facts.sub_series:
                    facts_lines.append("Existing sub_series:")
                    for s in existing_facts.sub_series:
                        facts_lines.append(f"  - {s.label}: {s.reason}")
                if not facts_lines:
                    facts_lines.append("Existing facts: (none)")
            else:
                facts_lines.append("Existing facts: (none)")

            if unnumbered and era_evidence_lines:
                header = (
                    f"== Finalize == {len(unnumbered)} included albums "
                    f"lack episode numbers AND era evidence found. "
                    f"Inspecting track listings and proposing facts...\n"
                )
            elif era_evidence_lines:
                header = (
                    "== Finalize == era evidence found. "
                    "Proposing era_boundaries / sub_series...\n"
                )
            else:
                header = (
                    f"== Finalize == {len(unnumbered)} included albums "
                    f"lack episode numbers. Inspecting track listings...\n"
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
                    "- Era evidence: propose era_boundaries "
                    "from flagged albums"
                )
            elif era_decisions and n_existing_eras:
                work_items.append(
                    f"- Era: {n_existing_eras} era_boundaries already "
                    f"documented, skip Step 2"
                )

            prompt_parts: list[str] = [
                f"Series: {meta.title!r}",
                f"Episode pattern: {shared_deps.pattern}",
            ]
            if work_items:
                prompt_parts.append(
                    "## Work items\n" + "\n".join(work_items)
                )
            prompt_parts.extend([
                "",
                "\n".join(facts_lines),
                "",
                "\n".join(era_evidence_lines),
            ])
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
                existing_facts=existing_facts or SeriesFacts(),
                all_decisions=all_decisions,
                on_progress=on_progress,
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
                    model_name=model_name,
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
                if finalize_result.proposed_pattern_update is not None:
                    shared_deps.pattern = finalize_result.proposed_pattern_update
                    shared_deps.pattern_revisions.append(
                        finalize_result.proposed_pattern_update,
                    )
                    on_progress(
                        f"  Finalize proposed pattern update -> "
                        f"{finalize_result.proposed_pattern_update}\n",
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
                err = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
                provider_errors.append(f"finalize: {err}")
                on_progress(
                    f"  Finalize phase failed: {exc}. "
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

    on_progress(f"  Finalize: {_fmt_elapsed(time.monotonic() - t_finalize)}\n")

    overall = _fmt_elapsed(time.monotonic() - t_overall)
    on_progress(
        f"\n== Done == {total_inc} included, {total_exc} excluded [{overall}]\n"
    )

    write_cover_cache(meta.id, all_discovered)

    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        episode_pattern=final_pattern,
        albums=all_decisions,
        provider_artist_ids=meta.provider_artist_ids,
        age_note=meta.age_note,
        curator_notes=meta.curator_notes,
        series_facts=merged_facts or SeriesFacts(),
        incomplete=incomplete,
        incomplete_reason="; ".join(provider_errors) if incomplete else "",
    )


# ── Dispatcher ────────────────────────────────────────────────────────────


async def run_curation(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 3600,
    existing_curation: dict | None = None,
    content_type: str = "hoerspiel",
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_facts: SeriesFacts | None = None,
    on_progress: Progress = _noop,
) -> CuratedSeries:
    """Pick single-agent or batched flow based on discography size."""
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        raise ValueError("OPENCODE_API_KEY not set")

    total_albums = 0
    known = known_artist_ids or {}
    for p in providers:
        ids = known.get(p.name) or []
        if not ids:
            artists = p.search_artists(query)
            if artists:
                ids = [artists[0].id]
        for aid in ids:
            albums = p.artist_albums(aid)
            total_albums += len(albums)

    on_progress(f"  {total_albums} albums, curating\n")
    result = await _run_large(
        query,
        providers,
        model_name=model_name,
        api_key=api_key,
        timeout=timeout,
        existing_curation=existing_curation,
        content_type=content_type,
        known_artist_ids=known_artist_ids,
        existing_facts=existing_facts,
        on_progress=on_progress,
    )

    result.content_type = content_type

    return result


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
    CURATION_DIR.mkdir(parents=True, exist_ok=True)
    path = CURATION_DIR / f"{series.id}.json"

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


def lookup_catalog_entry(query: str):
    """Resolve ``query`` to a CatalogEntry when it matches a known series.

    Returns the entry on first match (by ID or title) or None.
    """
    try:
        entries = load_catalog()
    except Exception:
        return None
    for entry in entries:
        if entry.id == query:
            return entry
    for entry in entries:
        if entry.title == query:
            return entry
    return None


def load_existing_facts(entry) -> SeriesFacts | None:
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
        # Carry facts from the prior curation JSON forward, not just the
        # frozen series.yaml facts: re-curation is an incremental update,
        # not a rediscovery from scratch. series.yaml wins on conflict.
        existing_facts = merge_facts(
            existing_facts,
            facts_from_curation(existing_curation),
        )
        series = await run_curation(
            query,
            providers,
            model_name=model,
            timeout=timeout,
            existing_curation=existing_curation,
            content_type=content_type,
            known_artist_ids=known_artist_ids,
            existing_facts=existing_facts,
            on_progress=on_progress,
        )
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
        return CurateOneResult(ok=True, series=series, path=path)
    except Exception as e:
        import traceback

        msg = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
        on_progress(f"Failed to curate {query}: {msg}")
        on_progress(traceback.format_exc())
        return CurateOneResult(ok=False, error=msg)


async def curate_all(
    providers: list[CatalogProvider],
    *,
    model: str = _DEFAULT_MODEL,
    timeout: int = 3600,
    force: bool = False,
    on_progress: Progress = _noop,
) -> CurateAllResult:
    """Curate all series in the catalog."""
    entries = load_catalog()
    total = len(entries)
    result = CurateAllResult(total=total)

    on_progress(
        f"Curating {total} series with {model}\n"
        f"Providers: {', '.join(p.name for p in providers)}\n"
        f"Force: {force}",
    )

    for i, entry in enumerate(entries):
        curation_path = CURATION_DIR / f"{entry.id}.json"
        existing: dict | None = None
        if curation_path.exists():
            if not force:
                result.skipped += 1
                continue
            existing = json.loads(curation_path.read_text())

        on_progress(
            f"\n({i + 1}/{total}) {entry.title} "
            f"({result.succeeded} done, {result.failed} failed, {result.skipped} skipped)",
        )

        entry_content_type = resolve_content_type(
            entry_content_type=entry.content_type,
            entry_has_pattern=bool(entry.episode_pattern),
            existing_content_type=(existing or {}).get("content_type"),
        )
        one_result = await curate_one(
            entry.title,
            providers,
            model=model,
            timeout=timeout,
            series_id=entry.id,
            known_artist_ids=entry.all_artist_ids() or None,
            existing_curation=existing,
            content_type=entry_content_type,
            existing_facts=load_existing_facts(entry),
            on_progress=on_progress,
        )
        if one_result.ok:
            result.succeeded += 1
        else:
            result.failed += 1
            result.failed_ids.append(entry.id)

    on_progress(
        f"\nResults: {result.succeeded} curated, "
        f"{result.skipped} skipped, {result.failed} failed",
    )
    if result.failed_ids:
        on_progress(f"Failed: {', '.join(result.failed_ids)}")

    return result
