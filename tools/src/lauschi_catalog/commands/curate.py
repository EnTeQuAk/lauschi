"""AI-assisted series curation across providers.

Uses pydantic-ai to analyze discographies from all configured providers,
decide which albums belong to the series, and extract episode numbers.

Albums are processed in batches of ~30. Each batch gets series context +
album metadata, and the AI can call get_album_details for anything
ambiguous. Fresh context per batch keeps things fast and reliable.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

import click
from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic_ai import Agent, ModelRetry, RunContext
from lauschi_catalog._opencode import build_mistral_model, build_opencode_model
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.analysis import analyze_series
from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.prompts import load_curate_skill





from lauschi_catalog.catalog.facts import (
    EraBoundaryProposal,
    KnownGapProposal,
    SeriesFacts,
    SubSeriesProposal,
)
from lauschi_catalog.catalog.matcher import compute_pattern_coverage as _compute_pattern_coverage
from lauschi_catalog.catalog.prompt import album_to_dict, format_albums_xml
from lauschi_catalog.providers import Album, CatalogProvider
from lauschi_catalog.providers._validate import explain_invalid, is_valid_id
from lauschi_catalog._opencode import get_model_settings
from lauschi_catalog.rate_limit import RateLimiter, run_with_rate_limit_retry
from lauschi_catalog.retry import is_retryable

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
CURATION_DIR.mkdir(parents=True, exist_ok=True)

_DEFAULT_MODEL = "kimi-k2.6"

_BATCH_SIZE = 30


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
                # Compress consecutive runs: 1,2,3,5,6 → 1-3, 5-6
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
        # Pick the top 3 most common reasons
        top = sorted(reasons.items(), key=lambda kv: kv[1], reverse=True)[:3]
        if top:
            reason_lines = [f"  {r} ({n})" for r, n in top]
            lines.append("Prior exclusions:")
            lines.extend(reason_lines)

    if batch_num > 1 and not lines:
        lines.append("No decisions from prior batches yet.")

    return "\n".join(lines) if lines else ""


def _restore_dropped_albums(
    decisions: list[AlbumDecision],
    album_index: dict[tuple[str, str], dict],
) -> None:
    """Add any discovered albums the agent omitted as 'not_decided'.

    Mutates ``decisions`` in place. The caller must have built
    ``album_index`` from the discovery-phase output so every omitted
    album can be reconstructed with its original title and
    release_date.
    """
    discovered_ids = set(album_index.keys())
    decided_ids = {(d.provider, d.album_id) for d in decisions}
    dropped = discovered_ids - decided_ids
    if not dropped:
        return

    console.print(
        f"  [yellow]⚠ {len(dropped)} discovered album(s) missing from "
        f"agent output — adding as 'not_decided'[/]",
    )
    for prov, aid in sorted(dropped):
        src = album_index.get((prov, aid))
        decisions.append(AlbumDecision(
            album_id=aid,
            provider=prov,
            include=False,
            title=src["name"] if src else "unknown",
            exclude_reason="not_decided: agent omitted this album",
            release_date=src.get("release_date") if src else None,
            episode_num=None,
        ))


# ── Output models ──────────────────────────────────────────────────────────

class AlbumDecision(BaseModel):
    """Decision for a single album from any provider."""

    album_id: str
    provider: str  # "spotify" or "apple_music"
    include: bool
    episode_num: int | None = Field(description="Episode number extracted from the album title using the series episode_pattern regex")
    title: str
    exclude_reason: str | None = None
    # Populated after the agent returns, by joining (provider, album_id)
    # against the discovery-phase album list. Persisted in the curation
    # JSON so the review and verify phases can render release_date in
    # their prompts without re-fetching from the provider, and so the
    # release-order strategy (when enabled) has the data it needs.
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
            raise ValueError(
                "include=False requires `exclude_reason` naming the failure-"
                "taxonomy pattern",
            )
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
    # Content type: "hoerspiel" (default), "music", or "audiobook".
    # Persisted in the curation JSON so re-curation picks the right AI prompt.
    content_type: Literal["hoerspiel", "music", "audiobook"] = "hoerspiel"
    # Structured facts discovered from the discography: era_boundaries,
    # known_gaps, sub_series. Proposed by curate (finalize agent), may be
    # overridden by review, flagged by verify, frozen into series.yaml.
    # Always present — empty lists mean "no facts discovered".
    series_facts: SeriesFacts = Field(default_factory=SeriesFacts)
    # True when a provider failed during discovery or returned zero
    # albums while another provider had data. Signals that the curation
    # may be incomplete and should be re-run once the provider issue
    # is resolved. Review escalates these automatically.
    incomplete: bool = False
    incomplete_reason: str = ""

    @field_validator("episode_pattern")
    @classmethod
    def _valid_pattern(cls, v: str | list[str] | None) -> str | list[str] | None:
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups < 1:
                msg = f"Pattern {p!r}: needs at least 1 capture group"
                raise ValueError(msg)
        return v

    def included(self) -> list[AlbumDecision]:
        return sorted(
            [a for a in self.albums if a.include],
            # Numbered episodes sort by number. Unnumbered (named
            # episodes, fairy tales, etc.) fall back to release_date
            # so users see them in chronological order rather than
            # alphabetical. The `is None` first element keeps the
            # numbered bucket ahead of the unnumbered without
            # inventing a magic-int sentinel; tuple compares stop
            # at the bool when buckets differ, so None never has
            # to compare against int.
            key=lambda a: (
                a.episode_num is None, a.episode_num,
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
        if v is None:
            return None
        patterns = [v] if isinstance(v, str) else v
        for p in patterns:
            c = re.compile(p)
            if c.groups < 1:
                msg = f"Pattern {p!r}: needs at least 1 capture group"
                raise ValueError(msg)
        return v


# ── Agent dependencies ─────────────────────────────────────────────────────

@dataclass
class Deps:
    providers: list[CatalogProvider]
    seen_albums: dict[str, list[dict]] = field(default_factory=dict)
    seen_details: dict[str, dict] = field(default_factory=dict)
    _search_count: int = field(default=0, init=False)
    _MAX_SEARCHES: int = 2


@dataclass
class BatchDeps:
    providers: list[CatalogProvider]
    seen_details: dict[str, dict] = field(default_factory=dict)
    # Pattern starts at whatever the metadata phase decided. The finalize
    # agent (post-batch) can revise it via propose_pattern_update when
    # track listings reveal a systematic format the metadata phase
    # missed. The final pattern is used to re-extract episode_num across
    # every decision at the end of the run.
    pattern: str | list[str] | None = None
    pattern_revisions: list[str | list[str]] = field(default_factory=list)
    # All discovery-phase titles, carried so the finalize agent's
    # propose_pattern_update tool can verify that a proposed regex
    # actually captures digits before accepting it. Without this, the
    # agent could propose `^(.+?) \(...\)$` (capturing story names,
    # not numbers) and silently install a dead pattern.
    titles: list[str] = field(default_factory=list)


@dataclass
class FinalizeDeps:
    """Deps for the metadata-finalization agent.

    Carries cached album details from the batch phase so the
    finalize agent can inspect track listings without re-fetching.
    Also carries existing frozen facts (from series.yaml) so the
    agent only proposes genuinely new ones.
    """

    providers: list[CatalogProvider]
    seen_details: dict[str, dict] = field(default_factory=dict)
    pattern: str | list[str] | None = None
    titles: list[str] = field(default_factory=list)
    existing_facts: SeriesFacts = field(default_factory=SeriesFacts)
    proposed_facts: SeriesFacts | None = field(default=None, init=False)
    all_decisions: list[AlbumDecision] = field(default_factory=list)


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
    """Output of the metadata-finalization agent.

    For included albums that the batch agent couldn't number from
    album titles alone, the finalize agent inspects track listings
    (especially track 1) to extract episode numbers and optionally
    proposes an updated episode_pattern.
    """

    episode_updates: list[EpisodeUpdate] = Field(
        default_factory=list,
        description="Albums where track listings revealed the episode number.",
    )
    proposed_pattern_update: str | list[str] | None = Field(
        default=None,
        description="If track listings reveal a systematic new format not caught by the current pattern, propose an updated regex. Null if no change needed.",
    )


@dataclass
class MetadataDeps:
    """Deps for the metadata-extraction agent.

    Carries the full discography titles so the agent's
    check_pattern_coverage tool can score a proposed episode_pattern
    against every album, not just the sample in the prompt.
    """
    titles: list[str]
    _pattern_check_count: int = field(default=0, init=False)
    _MAX_PATTERN_CHECKS: int = 5


def _stratified_sample(items: list, n: int) -> list:
    """Pick ``n`` items spread evenly across ``items`` rather than
    taking the head.

    Provider APIs return albums in some order (Spotify: roughly
    newest-first). Taking the first N can blind the metadata agent
    to era-specific naming conventions — e.g., ddF episodes 1-170
    use ``NNN/Title`` format and 175+ use ``Folge XXX:``. If the
    head-40 sample only contains the modern format, the agent emits
    a single-pattern regex and the older format silently loses its
    episode numbers across the entire run.
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
    from lauschi_catalog.catalog.matcher import extract_episode

    changed = 0
    for d in decisions:
        new_ep = extract_episode(pattern, d.title)
        if new_ep is not None and new_ep != d.episode_num:
            d.episode_num = new_ep
            changed += 1
    return changed


# ── Shared prompt fragments ──────────────────────────────────────────────

def _dry_run_prompts(query: str, content_type: str = "hoerspiel", discography_span_years: int | None = None) -> None:
    """Print assembled prompts without calling the API."""
    batch = load_curate_skill(phase="batch", content_type=content_type, discography_span_years=discography_span_years)
    metadata = load_curate_skill(phase="metadata", content_type=content_type, discography_span_years=discography_span_years)
    finalize = load_curate_skill(phase="finalize", content_type=content_type, discography_span_years=discography_span_years)

    console.print(Panel("Batch system prompt", border_style="blue"))
    console.print(batch)
    console.print()

    console.print(Panel("Metadata system prompt", border_style="blue"))
    console.print(metadata)
    console.print()

    console.print(Panel("Finalize system prompt", border_style="blue"))
    console.print(finalize)
    console.print()

    # Sample batch user prompt
    sample_batch = [
        {"provider": "spotify", "id": "abc123", "name": "Folge 1: Der Anfang", "total_tracks": 3, "release_date": "2020-01-15"},
        {"provider": "apple_music", "id": "def456", "name": "Folge 2: Die Reise", "total_tracks": 4, "release_date": "2020-03-20"},
    ]
    album_lines = "\n".join(
        f"  {a['provider']}:{a['id']} | {a['name']} | {a['total_tracks']} tracks | {a['release_date']}"
        for a in sample_batch
    )
    sample_user = (
        f"Series: {query!r}\n"
        f"Episode pattern: ^Folge (\\d+):\n"
        f"Progress: 0 included, 0 excluded.\n\n"
        f"Batch 1/1 (2 albums):\n\n{album_lines}"
    )
    console.print(Panel("Sample batch user prompt", border_style="blue"))
    console.print(sample_user)


# ── Agent builders ─────────────────────────────────────────────────────────


def _build_metadata_agent(
    model, *, model_name: str = "", content_type: str = "hoerspiel", discography_span_years: int | None = None,
) -> Agent[MetadataDeps, SeriesMetadata]:
    """Metadata-extraction agent.

    For Hörspiel series, the agent must call check_pattern_coverage
    before finalizing — that's how it learns whether the pattern it
    inferred from the sample actually covers the full discography.

    For music and audiobook artists, episode_pattern is meaningless
    (music albums and audiobook readings aren't numbered episodes), so
    the tool isn't registered and the prompt doesn't ask for
    verification. Without this split, a music metadata run obeys the
    "MUST call check_pattern_coverage" instruction with a None pattern,
    gets a tool error, and may invent a bogus pattern to satisfy the
    instruction.
    """
    system_prompt = load_curate_skill(phase="metadata", content_type=content_type, discography_span_years=discography_span_years)
    agent: Agent[MetadataDeps, SeriesMetadata] = Agent(
        model,
        output_type=SeriesMetadata,
        system_prompt=system_prompt,
        model_settings=get_model_settings("curate", model_name),
        tool_retries=2, output_retries=2,
    )

    if content_type in ("music", "audiobook"):
        return agent

    @agent.output_validator
    def _validate_metadata(ctx: RunContext[MetadataDeps], meta: SeriesMetadata) -> SeriesMetadata:
        """Post-output validation: ensure the agent tested its pattern."""
        if ctx.deps._pattern_check_count == 0:
            raise ModelRetry(
                "You must call check_pattern_coverage with your proposed "
                "episode_pattern before returning. If titles genuinely carry "
                "no episode numbers, set episode_pattern=None.",
            )
        if meta.episode_pattern:
            from lauschi_catalog.catalog.matcher import extract_episode
            matched = sum(
                1 for t in ctx.deps.titles
                if extract_episode(meta.episode_pattern, t) is not None
            )
            total = len(ctx.deps.titles)
            coverage = matched / total if total else 0
            # Tiered threshold: <30% is a hard fail (pattern is catastrophically
            # wrong), 30-80% is a soft fail (pattern works for the majority but
            # systematic misses remain — the agent should keep iterating).
            if coverage < 0.3:
                raise ModelRetry(
                    f"Coverage only {coverage:.0%} ({matched}/{total}). "
                    f"Legitimate episodes are being missed. Add a new regex "
                    f"pattern that matches the unmatched titles, or set "
                    f"episode_pattern=None if this series truly has no "
                    f"numbered episodes.",
                )
            if coverage < 0.8:
                # Find a few unmatched titles that look like they SHOULD match
                # (long titles with track counts, not obviously compilations)
                # to nudge the agent toward the right pattern shape.
                unmatched = [
                    t for t in ctx.deps.titles
                    if extract_episode(meta.episode_pattern, t) is None
                ][:10]
                raise ModelRetry(
                    f"Coverage {coverage:.0%} ({matched}/{total}) is below "
                    f"the 80% safe band. The unmatched titles likely contain "
                    f"systematic episode markers your pattern missed. "
                    f"Unmatched samples: {unmatched!r}. "
                    f"Look for episode numbers in suffixes, parentheses, or "
                    f"alternate prefixes. Add a regex alternation for the "
                    f"dominant missed shape, then re-test.",
                )
        return meta

    @agent.tool
    def check_pattern_coverage(
        ctx: RunContext[MetadataDeps],
        pattern: str | list[str],
    ) -> PatternCoverageReport:
        """Test a proposed episode_pattern against ALL discovered titles.

        Returns coverage stats. The pattern's first capture group MUST
        capture a digit string (the episode number). A title can fail
        in two distinct ways:
          - unmatched_regex_samples: the regex didn't find a match at all
          - non_numeric_capture_samples: regex matched but capture group 1
            wasn't an integer (e.g. you used `(.*)` and captured the
            whole title, or your group caught text instead of digits)

        If non_numeric_capture_samples is high, the regex itself is fine but
        the capture group is wrong — narrow group 1 to `(\\d+)`.

        If the discography uses named/themed episodes (fairy tales,
        themes) instead of numbers, no pattern can succeed: return
        episode_pattern=None without calling this tool again.

        Limited to 5 calls per run. If you've already tested 3+ patterns
        and coverage stays below 80%, set episode_pattern=None — the
        series likely uses named episodes.
        """
        ctx.deps._pattern_check_count += 1
        if ctx.deps._pattern_check_count > ctx.deps._MAX_PATTERN_CHECKS:
            console.print(
                f"  [yellow]⚠ check_pattern_coverage limit reached "
                f"({ctx.deps._pattern_check_count - 1}/{ctx.deps._MAX_PATTERN_CHECKS}). "
                f"Set episode_pattern=None or commit to your best pattern.[/]",
            )
            return PatternCoverageReport(
                limit_reached=True,
                message=f"Maximum {ctx.deps._MAX_PATTERN_CHECKS} pattern checks reached. "
                    "Set episode_pattern=None if coverage is below 80%, "
                    "or use your best pattern if coverage is acceptable.",
            )
        raw = _compute_pattern_coverage(ctx.deps.titles, pattern)
        if "error" not in raw:
            console.print(
                f"  [dim]✅ check_pattern_coverage({pattern!r}) → "
                f"{raw['matched']}/{raw['total']} = "
                f"{raw['coverage']:.0%}[/]",
            )
        return PatternCoverageReport(
            pattern=raw.get("pattern"),
            matched=raw.get("matched", 0),
            total=raw.get("total", 0),
            coverage=raw.get("coverage", 0.0),
            unmatched_regex_samples=raw.get("unmatched_regex_samples", []),
            non_numeric_capture_samples=raw.get("non_numeric_capture_samples", []),
        )

    return agent


def _build_batch_agent(model, *, model_name: str = "", content_type: str = "hoerspiel", discography_span_years: int | None = None) -> Agent[BatchDeps, BatchResult]:
    """Agent for processing one batch of albums."""
    system_prompt = load_curate_skill(phase="batch", content_type=content_type, discography_span_years=discography_span_years)
    agent: Agent[BatchDeps, BatchResult] = Agent(
        model,
        output_type=BatchResult,
        system_prompt=system_prompt,
        model_settings=get_model_settings("curate", model_name),
        tool_retries=2, output_retries=2,
    )

    return agent


def _build_finalize_agent(model, *, model_name: str = "", content_type: str = "hoerspiel", discography_span_years: int | None = None) -> Agent[FinalizeDeps, FinalizeResult]:
    """Agent for post-batch metadata finalization.

    Re-examines included albums that lack episode numbers by looking
    at track listings (especially track 1), which often carry the
    episode identifier even when the album title doesn't match the
    current pattern.
    """
    system_prompt = load_curate_skill(phase="finalize", content_type=content_type, discography_span_years=discography_span_years)
    agent: Agent[FinalizeDeps, FinalizeResult] = Agent(
        model,
        output_type=FinalizeResult,
        system_prompt=system_prompt,
        model_settings=get_model_settings("finalize", model_name),
        tool_retries=2, output_retries=2,
    )

    @agent.tool
    def get_album_details(
        ctx: RunContext[FinalizeDeps], provider: str, album_ids: list[str],
    ) -> list[dict]:
        """Fetch full album details (track listing) from a provider."""
        results = []
        invalid = [aid for aid in album_ids if not is_valid_id(provider, aid)]
        valid_ids = [aid for aid in album_ids if is_valid_id(provider, aid)]
        for bad in invalid:
            results.append({"id": bad, "error": explain_invalid(provider, bad)})

        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return results or []
        for aid in valid_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider, "id": album.id, "name": album.name,
                    "release_date": album.release_date,
                    "total_tracks": album.total_tracks,
                    "label": album.label,
                    "artists": album.artists,
                    "tracks": [{"name": t.name, "duration_ms": t.duration_ms}
                               for t in album.tracks[:10]],
                }
                ctx.deps.seen_details[key] = detail
                results.append(detail)
        return results

    @agent.tool
    def propose_pattern_update(
        ctx: RunContext[FinalizeDeps],
        patterns: list[str],
    ) -> str:
        """Propose an updated episode_pattern regex.

        Only use if track listings reveal a systematic new format that
        the current pattern doesn't catch. Verify the new pattern
        actually extracts digit/integer episode numbers from album titles
        (not just track names — the pattern must work on titles too).
        """
        if not patterns:
            return "patterns list cannot be empty"
        for p in patterns:
            try:
                compiled = re.compile(p)
            except re.error as e:
                return f"invalid regex {p!r}: {e}"
            if compiled.groups < 1:
                return f"pattern {p!r}: needs ≥1 capture group"

        if ctx.deps.titles:
            check = _compute_pattern_coverage(ctx.deps.titles, patterns)
            if "error" in check:
                return check["error"]
            if check["matched"] == 0:
                return (
                    f"pattern {patterns!r}: didn't match any album titles. "
                    f"Track-name-only patterns are not useful here."
                )

        new_pattern: str | list[str] = (
            patterns[0] if len(patterns) == 1 else list(patterns)
        )
        console.print(
            f"  [cyan]🔄 finalize propose_pattern_update → {new_pattern}[/]",
        )
        return f"Pattern updated to {new_pattern}."

    @agent.tool
    def lint_current_curation(
        ctx: RunContext[FinalizeDeps],
    ) -> list[str]:
        """Run deterministic structural checks on the current curation.

        Call this AFTER proposing facts or episode numbers to catch
        structural issues the batch phase may have missed: duplicate
        episodes per era, unconfirmed facts, pattern coverage gaps,
        cross-provider asymmetry, etc.

        Returns a list of human-readable issue strings. Empty list
        means no issues found.
        """
        # Build a partial curation dict from current state
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
                for d in ctx.deps.all_decisions
            ],
            "episode_pattern": ctx.deps.pattern,
            "series_facts": (
                ctx.deps.proposed_facts.model_dump()
                if ctx.deps.proposed_facts else None
            ),
        }
        from lauschi_catalog.commands.lint import lint_curation
        issues = lint_curation(partial_curation)
        if issues:
            console.print(
                f"  [yellow]⚠ Finalize lint: {len(issues)} issue(s)[/]"
            )
        return issues

    @agent.tool
    def propose_series_facts(
        ctx: RunContext[FinalizeDeps],
        era_boundaries: list[EraBoundaryProposal] = [],
        known_gaps: list[KnownGapProposal] = [],
        sub_series: list[SubSeriesProposal] = [],
    ) -> str:
        """Propose structured facts about the series.

        You may call this tool multiple times in a single finalize run;
        each call accumulates new facts. Only propose facts not already
        present in existing_facts or in facts proposed by a prior call.
        Each fact must have a clear justification based on the
        discography data (release_date clustering, title patterns).

        The tool validates inputs: empty labels or reasons will be
        rejected with a validation error you can fix and retry.
        """
        from lauschi_catalog.catalog.facts import EraBoundary, KnownGap, SubSeriesFact

        existing = ctx.deps.existing_facts
        # Start from any already-proposed facts in this run so multiple
        # calls accumulate rather than overwrite.
        if ctx.deps.proposed_facts is None:
            ctx.deps.proposed_facts = SeriesFacts()
        accumulated = ctx.deps.proposed_facts
        recorded: list[str] = []

        # era_boundaries
        all_labels = {e.label for e in existing.era_boundaries} | {e.label for e in accumulated.era_boundaries}
        for proposal in era_boundaries:
            if proposal.label in all_labels:
                continue
            accumulated.era_boundaries.append(EraBoundary(
                label=proposal.label,
                release_date_range=proposal.release_date_range,
                curated_by="curate",
            ))
            recorded.append(f"era: {proposal.label}")
            all_labels.add(proposal.label)

        # known_gaps
        all_nums = {g.number for g in existing.known_gaps} | {g.number for g in accumulated.known_gaps}
        for proposal in known_gaps:
            if proposal.number in all_nums:
                continue
            accumulated.known_gaps.append(KnownGap(
                number=proposal.number,
                reason=proposal.reason,
                curated_by="curate",
            ))
            recorded.append(f"gap: {proposal.number}")
            all_nums.add(proposal.number)

        # sub_series
        all_labels = {s.label for s in existing.sub_series} | {s.label for s in accumulated.sub_series}
        for proposal in sub_series:
            if proposal.label in all_labels:
                continue
            accumulated.sub_series.append(SubSeriesFact(
                label=proposal.label,
                album_ids=proposal.album_ids,
                reason=proposal.reason,
                curated_by="curate",
            ))
            recorded.append(f"sub: {proposal.label}")
            all_labels.add(proposal.label)

        if not recorded:
            return "No new facts proposed (all already documented or empty)."

        console.print(
            f"  [cyan]📊 propose_series_facts → {', '.join(recorded)}[/]",
        )
        return f"Recorded {len(recorded)} new fact(s): {', '.join(recorded)}"

    return agent


# ── Shared helpers ─────────────────────────────────────────────────────────

async def _run_agent(agent, prompt, deps):
    """Run an agent with streaming reasoning output."""
    async with agent.iter(
        prompt, deps=deps,
        usage_limits=UsageLimits(request_limit=200),
    ) as run:
        async for node in run:
            # Show AI reasoning as it streams in.
            if not hasattr(node, "model_response"):
                continue
            for part in node.model_response.parts:
                text = getattr(part, "content", None)
                if not isinstance(text, str) or len(text.strip()) <= 80:
                    continue
                kind = getattr(part, "part_kind", "")
                if kind == "thinking":
                    # Show thinking in a dim panel
                    # Escape ALL brackets — model reasoning can contain regex
                    # character classes like [/\.\-] which crash Rich's parser.
                    safe = escape(text.strip()[:500])
                    try:
                        console.print(
                            Panel(
                                safe,
                                border_style="dim",
                                title="💭 reasoning",
                                padding=(0, 1),
                            ),
                        )
                    except Exception:
                        # If even escaped text fails (edge case in Rich),
                        # skip the panel and continue — reasoning is diagnostic.
                        pass
        return run.result.output


# Re-export so existing tests/imports of curate._is_retryable keep
# working. New code should import is_retryable from
# lauschi_catalog.retry directly.
_is_retryable = is_retryable


async def _run_with_retry(
    coro_factory, *, phase: str = "", model_name: str = "",
):
    rate_limiter = RateLimiter(model_name) if model_name.startswith("mistral-") else None
    return await run_with_rate_limit_retry(
        coro_factory,
        phase=phase,
        model_name=model_name,
        rate_limiter=rate_limiter,
        max_retries=5,
        base_delay=5.0,
        max_delay=120.0,
        console=console,
    )


# ── Large discography flow (batched) ───────────────────────────────────────

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
) -> CuratedSeries:
    model = (
        build_mistral_model(model_name, api_key)
        if model_name.startswith("mistral-")
        else build_opencode_model(model_name, api_key)
    )

    # ── Step 1: Discovery — find artists + fetch discographies ─────────
    console.print("\n[bold cyan]Discovery[/]\n")

    all_albums: list[dict] = []
    artist_ids: dict[str, list[str]] = {}
    known_artist_ids = known_artist_ids or {}
    provider_errors: list[str] = []
    provider_album_counts: dict[str, int] = {}

    for p in providers:
        known = known_artist_ids.get(p.name) or []
        try:
            if known:
                # Canonical IDs from series.yaml. Skip search entirely; using
                # search_artists for known series risks picking the wrong
                # artist when there's a same-named band. This is the same
                # principle as _lock_series_id — series.yaml is authoritative
                # for identity.
                for aid in known:
                    artist_ids.setdefault(p.name, []).append(aid)
                    albums = p.artist_albums(aid)
                    console.print(
                        f"  [{p.name}] canonical artist: [{aid}] → {len(albums)} albums",
                    )
                    for a in albums:
                        all_albums.append({
                            "provider": p.name, "id": a.id, "name": a.name,
                            "release_date": a.release_date,
                            "total_tracks": a.total_tracks,
                        })
                continue

            artists = p.search_artists(query)
            if not artists:
                console.print(f"  [{p.name}] No artist found")
                continue

            # No canonical id → fall back to search. Log the chosen artist's
            # name (not just the id) so the user can spot wrong-disambiguation
            # at glance, and flag if the search returned multiple plausible
            # candidates so they know it's a guess.
            artist = artists[0]
            artist_ids.setdefault(p.name, []).append(artist.id)
            if len(artists) > 1:
                others = ", ".join(a.name for a in artists[1:4])
                console.print(
                    f"  [{p.name}] [yellow]chose[/] [bold]{artist.name}[/] "
                    f"[{artist.id}] (also matched: {others})",
                )
            else:
                console.print(
                    f"  [{p.name}] Artist: [bold]{artist.name}[/] [{artist.id}]",
                )

            albums = p.artist_albums(artist.id)
            for a in albums:
                all_albums.append({
                    "provider": p.name, "id": a.id, "name": a.name,
                    "release_date": a.release_date, "total_tracks": a.total_tracks,
                })
            console.print(f"  [{p.name}] {len(albums)} albums")
            provider_album_counts[p.name] = len(albums)
        except Exception as e:
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            console.print(f"  [red][{p.name}] Discovery failed: {err}[/]")
            provider_errors.append(f"{p.name}: {err}")

    # Mark as incomplete when a provider errors out, or when one
    # provider has zero albums while another has data.
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
        console.print(
            f"  [yellow]⚠ Curation marked incomplete: "
            f"{'; '.join(provider_errors)}[/]",
        )

    console.print(f"\n  Total: {len(all_albums)} albums across {len(providers)} providers\n")

    # ── Step 2a: Pre-fetch full album details ─────────────────────────
    # Every agent needs full metadata (tracks, label, duration) to make
    # good decisions. Fetching upfront eliminates reactive tool calls
    # in the batch agent and guarantees consistent metadata across all
    # pipeline phases.
    console.print("[dim]  Pre-fetching album details…[/]")
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
    console.print(f"  [dim]→ {len(prefetch_details)} albums with full metadata[/]\n")

    # ── Step 2: Metadata extraction (tiny call, no tools) ──────────────
    console.print("[bold cyan]Metadata[/]\n")

    all_titles = [a["name"] for a in all_albums]
    # Compute discography span for era_detection reference doc
    years = []
    for a in all_albums:
        rd = a.get("release_date")
        if rd and len(str(rd)) >= 4 and str(rd)[:4].isdigit():
            years.append(int(str(rd)[:4]))
    discography_span_years = (max(years) - min(years)) if len(years) >= 2 else None

    # Stratified sample so era-mixed series (older NNN/ titles + newer
    # Folge XXX: titles) hand the metadata agent evidence of both
    # naming conventions.
    sample_albums = _stratified_sample(all_albums, 40)
    provider_list = ", ".join(f"{k}: {v}" for k, v in artist_ids.items())

    metadata_agent = _build_metadata_agent(model, model_name=model_name, content_type=content_type, discography_span_years=discography_span_years)
    meta_deps = MetadataDeps(titles=all_titles)
    # Sample lines carry release_date and total_tracks alongside the
    # title. Title alone tells half the story for series where streaming
    # stripped the "Folge N:" prefix — release_date order can hint at
    # episode order, total_tracks separates singles from full Hörspiele.
    sample_lines = "\n".join(
        f"  - {a['name']} | {a['total_tracks']} tracks"
        f" | {a.get('release_date') or '?'}"
        for a in sample_albums
    )
    # ── Metadata extraction (with output validator for pattern check) ──
    meta = await _run_with_retry(
        lambda: asyncio.wait_for(
            _run_agent(
                metadata_agent,
                f"Series: {query!r}\nProviders: {provider_list}\n"
                f"Sample albums (title | tracks | release_date):\n"
                f"{sample_lines}",
                deps=meta_deps,
            ),
            timeout=1200,
        ),
        phase="metadata",
        model_name=model_name,
    )
    # Ensure artist IDs are in metadata
    if not meta.provider_artist_ids:
        meta.provider_artist_ids = artist_ids

    assert meta is not None

    console.print(
        f"  id={meta.id}  title={meta.title!r}  "
        f"pattern={meta.episode_pattern}  age={meta.age_note}\n",
    )

    # ── Step 3: Batched curation ───────────────────────────────────────
    batches = [
        all_albums[i : i + _BATCH_SIZE]
        for i in range(0, len(all_albums), _BATCH_SIZE)
    ]

    console.print(
        f"[bold cyan]Curation[/] — {len(all_albums)} albums in "
        f"{len(batches)} batches of ≤{_BATCH_SIZE}\n",
    )

    batch_agent = _build_batch_agent(model, model_name=model_name, content_type=content_type, discography_span_years=discography_span_years)
    # Shared deps across all batches: pattern revisions made by the
    # batch agent in batch N propagate to batch N+1's prompt, and at
    # the end we re-extract episode_num for every decision using the
    # final pattern. Without sharing, each batch starts fresh and the
    # signal is thrown away (the whole reason the previous run
    # silently dropped 250+ ddF episode numbers).
    shared_deps = BatchDeps(
        providers=providers,
        pattern=meta.episode_pattern,
        titles=all_titles,
        seen_details=prefetch_details,
    )

    all_decisions: list[AlbumDecision] = []
    total_inc = 0
    total_exc = 0
    episode_nums: list[int] = []

    for batch_num, batch in enumerate(batches, 1):
        # Progress context for the AI
        if episode_nums:
            progress = (
                f"Progress: {total_inc} included (episodes "
                f"{min(episode_nums)}–{max(episode_nums)}), "
                f"{total_exc} excluded."
            )
        else:
            progress = f"Progress: {total_inc} included, {total_exc} excluded."

        rolling = _build_batch_summary(
            all_decisions, shared_deps.pattern, batch_num,
        )

        # Build unified album metadata for the XML prompt
        batch_albums: list[dict] = []
        for a in batch:
            key = f"{a['provider']}:{a['id']}"
            detail = shared_deps.seen_details.get(key)
            if detail:
                batch_albums.append(detail)
            else:
                batch_albums.append({
                    "provider": a["provider"],
                    "id": a["id"],
                    "title": a["name"],
                    "episode_num": None,
                    "release_date": a.get("release_date", ""),
                    "album_type": "",
                    "total_tracks": a.get("total_tracks", 0),
                    "duration_min": None,
                    "label": "",
                    "artist": "",
                    "tracks": [],
                })
        album_xml = format_albums_xml(batch_albums, include_tracks=True)

        prompt = (
            f"Series: {meta.title!r}\n"
            f"Episode pattern: {shared_deps.pattern}\n"
            f"{progress}\n"
        )
        if rolling:
            prompt += f"{rolling}\n"
        prompt += (
            f"\nBatch {batch_num}/{len(batches)} ({len(batch)} albums):\n"
            f"\n"
            f"{album_xml}"
        )

        result: BatchResult = await _run_with_retry(
            lambda p=prompt: asyncio.wait_for(
                _run_agent(batch_agent, p, shared_deps), timeout=1200,
            ),
            phase=f"batch {batch_num}/{len(batches)}",
            model_name=model_name,
        )

        # Hydrate release_date from the discovery dict — the agent
        # doesn't (and shouldn't) echo this field, but we want it on
        # every decision so review/verify renders dates in their
        # prompts without re-fetching.
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

        console.print(
            f"  Batch {batch_num}/{len(batches)}: "
            f"[green]+{n_inc}[/] [red]-{n_exc}[/]  "
            f"(total: {total_inc} included, {total_exc} excluded)",
        )

        all_decisions.extend(result.albums)

        # Rate-limit pacing for providers with strict RPS limits
        # (e.g. Mistral free tier: ~0.83 requests/sec for small-2603).
        # Only sleep between batches, not after the last one.
        if batch_num < len(batches):
            await asyncio.sleep(4)

    console.print(
        f"\n  [bold]Total: [green]{total_inc} included[/]  "
        f"[red]{total_exc} excluded[/][/]\n",
    )

    # If any batch revised the pattern, re-extract episode_num across
    # every decision so earlier batches benefit from the correction.
    # The agent's include/exclude decisions remain valid (they're
    # based on content, not the regex), only the extracted number
    # field is updated.
    final_pattern = shared_deps.pattern
    if shared_deps.pattern_revisions and final_pattern is not None:
        re_extracted = _reextract_episode_numbers(all_decisions, final_pattern)
        console.print(
            f"  [cyan]Pattern revised mid-run: {meta.episode_pattern!r} "
            f"→ {final_pattern!r}. Re-extracted {re_extracted} episode "
            f"numbers across all batches.[/]\n",
        )

    # Detect silently-dropped albums: every discovered album must have a
    # decision. If the agent omitted one, add it as "not_decided" so the
    # human notices rather than it vanishing from the catalog.
    batch_index = {(a["provider"], a["id"]): a for a in all_albums}
    _restore_dropped_albums(all_decisions, batch_index)

    # ── Finalize metadata: facts discovery + episode extraction ──
    final_pattern = shared_deps.pattern
    proposed_facts: SeriesFacts | None = None
    if content_type not in ("music", "audiobook"):
        unnumbered = [
            d for d in all_decisions
            if d.include and d.episode_num is None
        ]

        # Pre-compute era evidence from batch-phase decisions so the
        # finalize agent sees it before the episode-numbering task.
        # Batch agents already identified era_collisions with per-album
        # notes — surfacing the summary prevents the agent from only
        # looking at unnumbered albums and missing the whole-discography
        # era structure.
        era_evidence_lines: list[str] = []
        era_decisions = [
            d for d in all_decisions
            if d.include and d.notes and "era" in d.notes.lower()
        ]
        if era_decisions:
            by_provider: dict[str, list[tuple[int, str, str]]] = {}
            for d in era_decisions:
                ep = d.episode_num
                if ep is None:
                    continue
                by_provider.setdefault(d.provider, []).append(
                    (ep, d.title, d.release_date or "?"),
                )
            era_evidence_lines.append(
                "### Batch-phase era evidence (review before proposing facts)",
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

        # Pre-compute structural analysis to feed into finalize. The
        # agent can spot duplicates/gaps/asymmetries itself, but
        # deterministic analysis prevents hallucinated structural
        # "findings" and grounds the agent's reasoning.
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
                    f"Gaps: {analysis['gap_count']} missing episodes "
                    f"({analysis['gaps'][:10]}{'…' if analysis['gap_count'] > 10 else ''})"
                )
            if analysis.get("duplicates_within_provider"):
                for prov, eps in analysis["duplicates_within_provider"].items():
                    analysis_lines.append(
                        f"Duplicates on {prov}: episodes {sorted(eps)}"
                    )
            if analysis.get("cross_provider_coverage"):
                for prov, cov in analysis["cross_provider_coverage"].items():
                    if cov.get("missing"):
                        analysis_lines.append(
                            f"{prov} missing: {cov['missing'][:10]}{'…' if len(cov['missing']) > 10 else ''}"
                        )
            if analysis.get("outliers"):
                analysis_lines.append(
                    f"Outlier title shapes: {len(analysis['outliers'])}"
                )
            if analysis.get("pattern_coverage") is not None:
                analysis_lines.append(
                    f"Pattern coverage: {analysis['pattern_coverage']:.0%}"
                )

        # Run finalize whenever there is EITHER unnumbered albums OR era
        # evidence. Facts discovery should not be gated on episode-number
        # gaps alone — eras can be fully numbered and still need
        # era_boundaries/sub_series.
        needs_finalize = bool(unnumbered) or bool(era_evidence_lines)
        if needs_finalize:
            lines: list[str] = []
            for d in unnumbered[:50]:  # cap to keep prompt size reasonable
                key = f"{d.provider}:{d.album_id}"
                detail = shared_deps.seen_details.get(key)
                tracks = ""
                if detail and detail.get("tracks"):
                    track_names = [t["name"] for t in detail["tracks"][:5]]
                    tracks = " | tracks: " + " | ".join(track_names[:3])
                lines.append(
                    f"  {d.provider}:{d.album_id} | {d.title}{tracks}"
                )
            facts_lines: list[str] = []
            if existing_facts:
                if existing_facts.era_boundaries:
                    facts_lines.append("Existing era_boundaries:")
                    for e in existing_facts.era_boundaries:
                        facts_lines.append(f"  - {e.label}: {e.release_date_range}")
                if existing_facts.known_gaps:
                    facts_lines.append("Existing known_gaps:")
                    for g in existing_facts.known_gaps:
                        facts_lines.append(f"  - Episode {g.number}: {g.reason}")
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
                    f"[bold cyan]Finalize[/] — {len(unnumbered)} included albums "
                    f"lack episode numbers AND era evidence found. "
                    f"Inspecting track listings and proposing facts...\n"
                )
            elif era_evidence_lines:
                header = (
                    f"[bold cyan]Finalize[/] — era evidence found. "
                    f"Proposing era_boundaries / sub_series...\n"
                )
            else:
                header = (
                    f"[bold cyan]Finalize[/] — {len(unnumbered)} included albums "
                    f"lack episode numbers. Inspecting track listings...\n"
                )
            console.print(header)

            finalize_agent = _build_finalize_agent(
                model, model_name=model_name, content_type=content_type,
                discography_span_years=discography_span_years,
            )

            prompt_parts: list[str] = [
                f"Series: {meta.title!r}",
                f"Episode pattern: {shared_deps.pattern}",
                "",
                "\n".join(facts_lines),
                "",
                "\n".join(era_evidence_lines),
            ]
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
            finalize_deps = FinalizeDeps(
                providers=providers,
                seen_details=shared_deps.seen_details,
                pattern=shared_deps.pattern,
                titles=all_titles,
                existing_facts=existing_facts,
                all_decisions=all_decisions,
            )
            try:
                finalize_result: FinalizeResult = await _run_with_retry(
                    lambda: asyncio.wait_for(
                        _run_agent(finalize_agent, finalize_prompt, finalize_deps),
                        timeout=1200,
                    ),
                    phase="finalize",
                    model_name=model_name,
                )
                # Apply episode updates
                updated = 0
                for upd in finalize_result.episode_updates:
                    for d in all_decisions:
                        if d.album_id == upd.album_id and d.provider == upd.provider:
                            d.episode_num = upd.episode_num
                            updated += 1
                            break
                if updated:
                    console.print(
                        f"  [green]Finalize set {updated} episode numbers from "
                        f"track listings.[/]\n",
                    )
                # Apply pattern update if proposed
                if finalize_result.proposed_pattern_update is not None:
                    shared_deps.pattern = finalize_result.proposed_pattern_update
                    shared_deps.pattern_revisions.append(
                        finalize_result.proposed_pattern_update,
                    )
                    console.print(
                        f"  [cyan]🔄 Finalize proposed pattern update → "
                        f"{finalize_result.proposed_pattern_update}[/]\n",
                    )
                # Collect proposed facts
                proposed_facts = finalize_deps.proposed_facts
                if proposed_facts:
                    n_new = len(proposed_facts.era_boundaries) + len(proposed_facts.known_gaps) + len(proposed_facts.sub_series)
                    if n_new:
                        console.print(
                            f"  [cyan]📊 Finalize proposed {n_new} new fact(s)[/]\n",
                        )
            except Exception as exc:
                console.print(
                    f"  [yellow]⚠ Finalize phase failed: {exc}. "
                    f"Proceeding with batch results.[/]\n",
                )

        # Re-extract episode numbers with the final pattern (post-finalize)
        final_pattern = shared_deps.pattern
        if shared_deps.pattern_revisions and final_pattern is not None:
            from lauschi_catalog.catalog.matcher import extract_episode

            re_extracted = _reextract_episode_numbers(all_decisions, final_pattern)
            if re_extracted:
                console.print(
                    f"  [cyan]Pattern revised: {meta.episode_pattern!r} "
                    f"→ {final_pattern!r}. Re-extracted {re_extracted} episode "
                    f"numbers across all batches.[/]\n",
                )

    # Merge existing + proposed facts for the output
    merged_facts: SeriesFacts | None = None
    if existing_facts or proposed_facts:
        merged_facts = SeriesFacts()
        merged_facts.era_boundaries.extend(existing_facts.era_boundaries)
        merged_facts.known_gaps.extend(existing_facts.known_gaps)
        merged_facts.sub_series.extend(existing_facts.sub_series)
        if proposed_facts:
            merged_facts.era_boundaries.extend(proposed_facts.era_boundaries)
            merged_facts.known_gaps.extend(proposed_facts.known_gaps)
            merged_facts.sub_series.extend(proposed_facts.sub_series)

    return CuratedSeries(
        id=meta.id,
        title=meta.title,
        aliases=meta.aliases,
        episode_pattern=final_pattern,
        albums=all_decisions,
        provider_artist_ids=meta.provider_artist_ids,
        age_note=meta.age_note,
        curator_notes=meta.curator_notes,
        series_facts=merged_facts,
        incomplete=incomplete,
        incomplete_reason="; ".join(provider_errors) if incomplete else "",
    )


# ── Dispatcher ─────────────────────────────────────────────────────────────

async def run_curation(
    query: str,
    providers: list[CatalogProvider],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 1800,
    existing_curation: dict | None = None,
    content_type: str = "hoerspiel",
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_facts: SeriesFacts | None = None,
) -> CuratedSeries:
    """Pick single-agent or batched flow based on discography size."""
    if model_name.startswith("mistral-"):
        api_key = os.environ.get("MISTRAL_API_KEY", "")
        if not api_key:
            console.print("[red]MISTRAL_API_KEY not set[/red]")
            raise SystemExit(1)
    else:
        api_key = os.environ.get("OPENCODE_API_KEY", "")
        if not api_key:
            console.print("[red]OPENCODE_API_KEY not set[/red]")
            raise SystemExit(1)

    # Probe total album count across providers (results are cached by the
    # provider's diskcache, so _run_large won't re-fetch). Use canonical
    # artist IDs when available so the probe doesn't take its own
    # disambiguation guess different from _run_large's.
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

    console.print(f"  {total_albums} albums — curating\n")
    result = await _run_large(
        query, providers,
        model_name=model_name, api_key=api_key,
        timeout=timeout, existing_curation=existing_curation,
        content_type=content_type,
        known_artist_ids=known_artist_ids,
        existing_facts=existing_facts,
    )

    # Persist content type so re-curation uses the right prompt.
    result.content_type = content_type

    return result


# ── Save / display ────────────────────────────────────────────────────────

def save_curation(series: CuratedSeries) -> Path:
    """Persist curate's findings into the curation JSON.

    The JSON file is canonical state shared across pipeline steps —
    curate, review, verify each own specific subkeys. This function
    reads the existing file (if any) and overwrites only the
    curate-owned fields (id, title, episode_pattern, albums, etc.).
    Anything we don't touch — review block, future fields owned by
    other pipeline steps — is naturally preserved. Same pattern
    save_review uses on its side.
    """
    path = CURATION_DIR / f"{series.id}.json"

    data: dict = {}
    if path.exists():
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            # Don't silently overwrite an existing-but-unparseable file.
            # The risk: if the JSON had an approved review block (human
            # curation work) and got partially corrupted, restarting
            # from data={} would discard that work on the next save.
            # Surface loudly and abort; the user can inspect, repair,
            # or move the file aside before re-running.
            console.print(
                f"[red]Refusing to overwrite unreadable curation file[/red]\n"
                f"  Path: {path}\n"
                f"  Error: {type(exc).__name__}: {exc}\n"
                f"  This file may contain approved review state. "
                f"Inspect it before re-curating; rename/remove the file "
                f"if you intend to start fresh.",
            )
            raise SystemExit(1)

    # If the album list changed substantively (different count or IDs),
    # action proposals in the review block reference stale album IDs.
    # Clear them so the next review starts from a clean slate.
    old_albums = data.get("albums", [])
    new_album_ids = {a.album_id for a in series.albums}
    old_album_ids = {a.get("album_id") for a in old_albums if a.get("album_id")}
    if old_album_ids and new_album_ids != old_album_ids:
        review = data.get("review", {})
        if review:
            for key in ("overrides", "splits", "added_albums", "pattern_update"):
                review.pop(key, None)
            # Reset verification too since review state changed
            review.pop("verification", None)
            data["review"] = review
        console.print(
            f"  [yellow]Album set changed ({len(old_album_ids)} → {len(new_album_ids)}). "
            f"Cleared stale review action proposals.[/yellow]"
        )

    data.update({
        "id": series.id,
        "title": series.title,
        "content_type": series.content_type,
        "aliases": series.aliases,
        "episode_pattern": series.episode_pattern,
        "provider_artist_ids": series.provider_artist_ids,
        "age_note": series.age_note,
        "curator_notes": series.curator_notes,
        "series_facts": series.series_facts.model_dump(),
        "curated_at": datetime.now(UTC).isoformat(),
        "albums": [a.model_dump() for a in series.albums],
        "incomplete": series.incomplete,
        "incomplete_reason": series.incomplete_reason,
    })

    canonicalize(data)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


def print_summary(series: CuratedSeries):
    included = series.included()
    excluded = [a for a in series.albums if not a.include]
    eps = [a.episode_num for a in included if a.episode_num is not None]
    providers_used = sorted(set(a.provider for a in included))

    ep_pat = series.episode_pattern or "(none)"
    pattern = escape(str(ep_pat))

    console.print(Panel(
        f"[bold]{escape(series.title)}[/]  [dim]{series.id}[/]\n"
        f"Providers: {', '.join(f'{k}: {v}' for k, v in series.provider_artist_ids.items())}\n"
        f"Episodes: {len(included)} included · {len(excluded)} excluded\n"
        f"Range: {min(eps) if eps else '—'}–{max(eps) if eps else '—'}\n"
        f"Pattern: {pattern}",
        title="✅ Curated",
        border_style="green",
    ))

    # Gap detection
    if eps:
        gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
        if gaps:
            console.print(
                f"[yellow]⚠ Gaps: {gaps[:20]}"
                f"{'…' if len(gaps) > 20 else ''}[/]",
            )

    # Episode table
    table = Table(box=box.SIMPLE, title=f"Included (first 10 of {len(included)})")
    table.add_column("Ep", width=5, justify="right")
    table.add_column("Provider", width=12)
    table.add_column("Title", min_width=40)
    table.add_column("ID", width=14, style="dim")
    for a in included[:10]:
        table.add_row(
            str(a.episode_num) if a.episode_num else "—",
            a.provider, a.title[:50], a.album_id[:14],
        )
    if len(included) > 10:
        table.add_row("…", "", f"({len(included) - 10} more)", "")
    console.print(table)

    if series.age_note:
        console.print(f"\n👶 Age: {series.age_note}")

    if series.curator_notes:
        console.print(f"\n[dim]Notes: {escape(series.curator_notes[:200])}[/]")

    if excluded:
        console.print(f"\n[dim]Excluded ({len(excluded)}):[/dim]")
        for a in excluded[:5]:
            console.print(f"  [dim]{a.provider}: {a.title} — {a.exclude_reason}[/dim]")

    console.print(f"\n[dim]Review with: mise run catalog-review-ai -- {series.id}[/]")


# ── CLI ────────────────────────────────────────────────────────────────────

def _init_providers(provider: str, *, no_cache: bool = False) -> list[CatalogProvider]:
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider(use_cache=not no_cache))
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider(use_cache=not no_cache))
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if not providers:
        console.print("[red]No providers available[/red]")
        raise SystemExit(1)
    return providers


def _lookup_catalog_entry(query: str):
    """Resolve ``query`` to a CatalogEntry when it matches a known series.

    ``query`` may be the user-typed ID (``detlev_joecker``) or the
    proper title (``Detlev Jöcker``). Returns the entry on first
    match or None when the query doesn't correspond to anything in
    series.yaml — that's a brand-new series the agent will discover
    and the caller falls back to the no-yaml path.

    Centralized so both the single-series CLI and any future caller
    (e.g. a re-curate-by-id tool) share one resolution rule.
    """
    from lauschi_catalog.catalog.loader import load_catalog

    try:
        entries = load_catalog()
    except Exception:
        return None
    # Exact id match wins over title (cheaper to type, no ambiguity).
    for entry in entries:
        if entry.id == query:
            return entry
    for entry in entries:
        if entry.title == query:
            return entry
    return None


def _resolve_content_type(
    entry_content_type: str | None,
    entry_has_pattern: bool,
    existing_content_type: str | None,
) -> Literal["hoerspiel", "music", "audiobook"]:
    """Decide the content_type for curation.

    series.yaml is canonical: an explicit content_type there wins over
    everything else. This prevents the failure mode where a one-time
    misclassification in the curation file compounds across every
    --force re-curate. Resolution order:

    1. Explicit ``content_type`` on the catalog entry → that value.
    2. ``episode_pattern`` on the entry → hoerspiel (patterns are only
       meaningful for episode-numbered content).
    3. Existing curation file's ``content_type`` → legacy escape hatch.
    4. Default → hoerspiel (most of the catalog).
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


def _load_existing_facts(entry) -> SeriesFacts | None:
    """Load frozen facts from a CatalogEntry, if any.

    Centralized so both single-series CLI and --all batch paths share
    one loading rule.
    """
    if entry.series_facts:
        return SeriesFacts.model_validate(entry.series_facts)
    return SeriesFacts()


def _lock_series_id(series: CuratedSeries, canonical_id: str | None) -> CuratedSeries:
    """Force ``series.id`` to the canonical value when one is known.

    The metadata agent occasionally invents an id that doesn't match
    the canonical entry in series.yaml. The trigger is series titles
    with characters that fail the ``^[a-z][a-z0-9_]*$`` pattern —
    notably umlauts. pydantic-ai retries on validation failure with
    the error fed back to the model, and the retry sometimes produces
    sloppy transliterations: ``benjamin_blümchen`` → ``benjamin_bluechen``
    (lost both the umlaut→ue mapping and a literal ``m``).

    The previous-run consequence: a typo'd JSON file orphaned next to
    the canonical one. ``series.yaml`` is the source of truth for the
    id, so we override here and tell the user it happened.
    """
    if canonical_id and series.id != canonical_id:
        console.print(
            f"  [yellow]Locked id to canonical: {series.id!r} → "
            f"{canonical_id!r} (model output overridden by series.yaml)[/]",
        )
        series.id = canonical_id
    return series


def _curate_one(
    query: str,
    providers: list[CatalogProvider],
    *,
    model: str,
    timeout: int,
    series_id: str | None = None,
    known_artist_ids: dict[str, list[str]] | None = None,
    existing_curation: dict | None = None,
    content_type: str = "hoerspiel",
    dry_run: bool = False,
    existing_facts: SeriesFacts | None = None,
) -> Path | None:
    if dry_run:
        console.print(f"  [cyan]Mode: {content_type} (dry run)[/]")
        _dry_run_prompts(query, content_type=content_type)
        return None
    try:
        if content_type == "music":
            console.print(f"  [cyan]Mode: music artist (not Hörspiel)[/]")
        series = asyncio.run(
            run_curation(
                query, providers,
                model_name=model, timeout=timeout,
                existing_curation=existing_curation,
                content_type=content_type,
                known_artist_ids=known_artist_ids,
                existing_facts=existing_facts,
            ),
        )
        _lock_series_id(series, series_id)
        path = save_curation(series)
        print_summary(series)
        console.print(f"[green]Saved to {path}[/green]")
        return path
    except Exception as e:
        # Some SDK exceptions have an empty str(e); fall back to the
        # type name so "Failed to curate Foo:" never appears blank.
        # escape() the message because pydantic-ai/regex error strings
        # can contain bracket-shaped fragments that Rich would parse
        # as markup and crash with MarkupError.
        msg = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
        console.print(f"[red]Failed to curate {query}: {escape(msg)}[/red]")
        return None


@click.command()
@click.argument("query", required=False)
@click.option("--all", "run_all", is_flag=True, help="Curate all series in the catalog")
@click.option("--force", is_flag=True, help="Re-curate even if curation JSON exists")
@click.option("--model", default=_DEFAULT_MODEL, help="AI model to use")
@click.option(
    "--timeout", default=3600,
    help="Timeout per series in seconds (default 60 min). Big series "
    "with many batches and tool calls genuinely take 30+ min; the old "
    "1800 default was timing out 14 series in the catalog.",
)
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
@click.option("--no-cache", is_flag=True, help="Bypass provider API cache")
@click.option("--music", is_flag=True, help="Curate as music artist (not Hörspiel series)")
@click.option("--content-type", type=click.Choice(["hoerspiel", "music", "audiobook"]), default=None, help="Content type override")
@click.option("--dry-run", is_flag=True, help="Print assembled prompts without calling the API")
def curate(
    query: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
    no_cache: bool,
    music: bool,
    content_type: str | None,
    dry_run: bool,
):
    """AI-curate a Hörspiel series or music artist across providers.

    Pass a series name to curate one, or --all to curate the entire catalog.
    Existing curations are skipped unless --force is given.
    Use --music for children's music artists (includes albums, not episodes).
    """
    if not query and not run_all:
        console.print("[red]Provide a series name or use --all[/red]")
        raise SystemExit(1)

    providers = _init_providers(provider, no_cache=no_cache)
    provider_names = ", ".join(p.name for p in providers)

    # Resolve content_type from flags: explicit --content-type wins, then
    # --music alias for backward compat.
    cli_content_type: str | None = content_type
    if cli_content_type is None and music:
        cli_content_type = "music"

    if query and not run_all:
        # When the query matches a known catalog entry, use yaml as
        # canonical for content_type, artist_ids, and series_id —
        # same architectural rule as --all mode and as _lock_series_id.
        entry = _lookup_catalog_entry(query)
        if entry is not None:
            existing: dict | None = None
            curation_path = CURATION_DIR / f"{entry.id}.json"
            if curation_path.exists():
                try:
                    existing = json.loads(curation_path.read_text())
                except (OSError, json.JSONDecodeError):
                    existing = None
            entry_content_type = _resolve_content_type(
                entry_content_type=entry.content_type,
                entry_has_pattern=bool(entry.episode_pattern),
                existing_content_type=(existing or {}).get("content_type"),
            )
            # CLI override wins over yaml for one-off experiments
            resolved_type = cli_content_type or entry_content_type
            console.print(
                Panel(
                    f"Curating [bold]{entry.title}[/bold] with {model}\n"
                    f"Catalog id: {entry.id}\n"
                    f"Content type: {resolved_type}\n"
                    f"Providers: {provider_names}",
                    title="lauschi-catalog curate",
                ),
            )
            if cli_content_type and cli_content_type != entry_content_type:
                console.print(
                    f"[yellow]Note: --content-type {cli_content_type} overrides "
                    f"series.yaml value {entry_content_type}. "
                    f"Edit series.yaml to make permanent.[/yellow]",
                )
            path = _curate_one(
                entry.title, providers,
                model=model, timeout=timeout,
                series_id=entry.id,
                known_artist_ids=entry.all_artist_ids() or None,
                existing_curation=existing,
                content_type=resolved_type,
                dry_run=dry_run,
                existing_facts=_load_existing_facts(entry),
            )
            if path is None and not dry_run:
                raise SystemExit(1)
            return

        # New series not yet in series.yaml — trust the user's flags.
        resolved_type = cli_content_type or "hoerspiel"
        console.print(
            Panel(
                f"Curating [bold]{query}[/bold] with {model}\n"
                f"Providers: {provider_names}\n"
                f"[dim]Not in series.yaml; treating as new "
                f"{resolved_type}.[/dim]",
                title="lauschi-catalog curate",
            ),
        )
        path = _curate_one(query, providers, model=model, timeout=timeout, content_type=resolved_type, dry_run=dry_run)
        if path is None and not dry_run:
            raise SystemExit(1)
        return

    # --all mode
    from lauschi_catalog.catalog.loader import load_catalog

    entries = load_catalog()
    total = len(entries)
    skipped = 0
    succeeded = 0
    failed = 0
    failed_ids: list[str] = []

    console.print(
        Panel(
            f"Curating [bold]{total} series[/bold] with {model}\n"
            f"Providers: {provider_names}\n"
            f"Force: {force}",
            title="lauschi-catalog curate --all",
        ),
    )

    for i, entry in enumerate(entries):
        curation_path = CURATION_DIR / f"{entry.id}.json"
        existing = None
        if curation_path.exists():
            if not force:
                skipped += 1
                continue
            existing = json.loads(curation_path.read_text())

        console.print(
            f"\n[bold]({i + 1}/{total})[/bold] {entry.title} "
            f"[dim]({succeeded} done, {failed} failed, {skipped} skipped)[/dim]",
        )

        entry_content_type = _resolve_content_type(
            entry_content_type=entry.content_type,
            entry_has_pattern=bool(entry.episode_pattern),
            existing_content_type=(existing or {}).get("content_type"),
        )
        path = _curate_one(
            entry.title, providers,
            model=model, timeout=timeout,
            series_id=entry.id,
            known_artist_ids=entry.all_artist_ids() or None,
            existing_curation=existing,
            content_type=entry_content_type,
            dry_run=dry_run,
            existing_facts=_load_existing_facts(entry),
        )
        if path:
            succeeded += 1
        else:
            failed += 1
            failed_ids.append(entry.id)

    console.print(
        f"\n[bold]Results:[/bold] {succeeded} curated, "
        f"{skipped} skipped, {failed} failed",
    )
    if failed_ids:
        console.print(f"[red]Failed: {', '.join(failed_ids)}[/red]")
