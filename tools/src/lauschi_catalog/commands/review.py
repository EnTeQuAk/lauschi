"""AI-assisted review of curated series data.

Reads a curation JSON, analyzes it for issues (sub-series duplicates, gaps,
era variants), and writes non-destructive review decisions: overrides to
exclude, additions for gaps, and split proposals for content that belongs
in a separate series entry.

Ported from scripts/review-series.py with multi-provider support.
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path

import click

from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext, ToolOutput
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich.console import Console
from rich.panel import Panel

from lauschi_catalog.catalog.analysis import analyze_series, effective_albums
from lauschi_catalog.providers import CatalogProvider

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_DEFAULT_MODEL = "kimi-k2.5"
_MAX_RETRIES = 3
_RETRY_DELAY = 5


# ── Output models ──────────────────────────────────────────────────────────

class ReviewOverride(BaseModel):
    album_id: str
    provider: str
    action: str  # "exclude" or "include"
    reason: str


class SplitProposal(BaseModel):
    new_series_id: str
    new_series_title: str
    album_ids: list[str]
    provider: str
    reason: str


class AddedAlbum(BaseModel):
    album_id: str
    provider: str
    title: str
    episode_num: int | None = Field(
        description="Episode number extracted from the title via the series "
        "pattern, or null when the title carries no number.",
    )
    # ``include`` and ``exclude_reason`` mirror the shape of regular albums
    # in data["albums"] so save_review can merge without post-processing.
    include: bool = True
    exclude_reason: str | None = None
    # Required so pydantic-ai treats it as a mandatory field in the model's
    # output schema. With a default, the model would silently skip it and
    # validate_add_evidence would never run. Tool-driven adds always supply
    # a URL via the add_album signature.
    evidence_url: str = Field(
        description="URL from web_search or fetch_page that confirms this "
        "album belongs to the series. Must NOT be a provider URL "
        "(open.spotify.com, music.apple.com).",
    )


# ``deferred_to_human`` is the universal escape hatch. Defined once and
# reused on every verdict enum so callers can ``== Verdict.DEFERRED``
# without repeating the string literal.
_DEFERRED = "deferred_to_human"

# Marker appended to a decision's reasoning when the validator coerces
# its verdict from an action verdict to ``deferred_to_human``. Used by
# the test suite to assert coercion happened.
_AUTO_DOWNGRADE_SUFFIX = " [auto-downgraded: agent did not populate the action list]"


class DuplicatesVerdict(StrEnum):
    """Within-provider episode-number collisions (kids see same story twice)."""
    RESOLVED_VIA_OVERRIDES = "resolved_via_overrides"
    NONE_FOUND = "no_within_provider_duplicates"
    DEFERRED = _DEFERRED


class SubSeriesVerdict(StrEnum):
    """Whether multiple title clusters represent distinct sub-series."""
    SPLITS_PROPOSED = "splits_proposed"
    NONE_FOUND = "no_sub_series_mixed_in"
    ERA_VARIANTS_KEPT = "era_variants_kept"
    DEFERRED = _DEFERRED


class GapsVerdict(StrEnum):
    """Missing episode numbers in the sequence."""
    FILLED_VIA_ADD_ALBUM = "filled_via_add_album"
    VERIFIED_CONTENT_ROTATION = "verified_content_rotation"
    NONE_PRESENT = "no_gaps_present"
    DEFERRED = _DEFERRED


class PatternVerdict(StrEnum):
    """Whether the episode_pattern regex correctly extracts numbers."""
    PATTERN_UPDATED = "pattern_updated"
    CURRENT_PATTERN_CORRECT = "current_pattern_correct"
    NOT_APPLICABLE_FOR_MUSIC = "not_applicable_for_music"
    DEFERRED = _DEFERRED


class OutliersVerdict(StrEnum):
    """Singleton-shape titles (specials, compilations, accidental content)."""
    EXCLUDED_VIA_OVERRIDES = "excluded_via_overrides"
    LEGITIMATE_SPECIALS_KEPT = "legitimate_specials_kept"
    NONE_FOUND = "no_outliers_found"
    DEFERRED = _DEFERRED


class CrossProviderVerdict(StrEnum):
    """Asymmetry between Spotify and Apple Music coverage."""
    VERIFIED_CONTENT_ROTATION = "verified_content_rotation"
    BALANCED = "balanced"
    SINGLE_PROVIDER_ONLY = "single_provider_only"
    DEFERRED = _DEFERRED


class _CategoryDecision(BaseModel):
    """Common shape for a per-category verdict. ``verdict`` is overridden
    in each subclass with a ``StrEnum`` type so the model has to commit
    to one of a small set of discrete states."""
    # Tight max_length forces the model to be terse. Without a bound,
    # models tend to dump structured intent into the most permissive
    # text field — including JSON-like prose describing overrides or
    # splits. Capping at 350 chars per decision keeps the contract
    # honest: structured data goes in structured fields.
    reasoning: str = Field(
        description="One sentence justifying the chosen verdict. Concrete and "
        "specific to this category — don't repeat the overall summary.",
        max_length=350,
    )


class DuplicatesDecision(_CategoryDecision):
    verdict: DuplicatesVerdict


class SubSeriesDecision(_CategoryDecision):
    verdict: SubSeriesVerdict


class GapsDecision(_CategoryDecision):
    verdict: GapsVerdict


class PatternDecision(_CategoryDecision):
    verdict: PatternVerdict


class OutliersDecision(_CategoryDecision):
    verdict: OutliersVerdict


class CrossProviderDecision(_CategoryDecision):
    verdict: CrossProviderVerdict


class StructuralReview(BaseModel):
    """The agent must commit to a verdict for every analysis category.

    No free-form notes field exists at this level: each piece of
    reasoning is scoped to a specific category. This forces the model
    to organize its thinking around the same axes downstream code (and
    a future UI) cares about, instead of dumping a wall of prose.
    """
    duplicates: DuplicatesDecision
    sub_series: SubSeriesDecision
    gaps: GapsDecision
    pattern: PatternDecision
    outliers: OutliersDecision
    cross_provider: CrossProviderDecision


class ReviewResult(BaseModel):
    """The agent's final structured output.

    Just two fields: a per-category decision tree and a short overall
    summary. Action proposals (overrides, splits, added albums, pattern
    updates) do NOT live here — they're collected via tool calls during
    the agent run and merged in by ``assemble_review``. Keeping the
    model output this small is the architectural commitment: emit only
    what the model is reliable at producing.
    """
    decisions: StructuralReview
    summary: str = Field(
        description="1-3 sentence overall verdict on the curation. Per-category "
        "findings live in decisions[*].reasoning. Do NOT include structured "
        "data (album_ids, JSON-like content) here.",
        # 500 chars ≈ 3 sentences. Even if the model tries to pack
        # structured intent into prose, this cap forecloses it.
        max_length=500,
    )


@dataclass
class AssembledReview:
    """The shape ``save_review`` writes.

    Combines the model's output (``decisions``, ``summary``) with the
    tool-driven action proposals collected on Deps during the run.
    Built deterministically by ``assemble_review``; never directly
    emitted by the model.
    """
    overrides: list[ReviewOverride]
    splits: list[SplitProposal]
    added_albums: list[AddedAlbum]
    pattern_update: str | list[str] | None
    decisions: StructuralReview
    summary: str


# ── Dependencies ───────────────────────────────────────────────────────────

@dataclass
class Deps:
    """Per-run state. Tools accumulate proposed actions here; the
    assembler reads them back at the end of the run.

    Three flavors of fields:
    - ``providers`` and ``curation`` are inputs (set on construction).
    - ``proposed_overrides`` / ``proposed_splits`` / ``added_albums`` /
      ``proposed_pattern_update`` are populated by the action tools.
    - ``_*_count`` track tool-call usage against ``_MAX_*`` caps.
    """
    providers: list[CatalogProvider]
    curation: dict
    proposed_overrides: list[dict] = field(default_factory=list)
    proposed_splits: list[dict] = field(default_factory=list)
    added_albums: list[dict] = field(default_factory=list)
    proposed_pattern_update: str | list[str] | None = field(default=None, init=False)
    seen_details: dict[str, dict] = field(default_factory=dict)
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _details_count: int = field(default=0, init=False)
    _override_count: int = field(default=0, init=False)
    _split_count: int = field(default=0, init=False)
    _add_count: int = field(default=0, init=False)
    _pattern_count: int = field(default=0, init=False)
    # Hard caps prevent runaway tool loops. Sized for real catalog
    # workloads: BB-scale curations have proposed up to ~12 overrides
    # and ~3 splits historically. The 30/10 caps comfortably exceed
    # observed needs while still capping budget if the model loops.
    _MAX_SEARCHES: int = 5
    _MAX_FETCHES: int = 3
    _MAX_DETAILS: int = 10
    _MAX_OVERRIDES: int = 30
    _MAX_SPLITS: int = 10
    _MAX_ADDS: int = 10
    _MAX_PATTERN_UPDATES: int = 3


_SYSTEM_PROMPT = """\
You review curated Hörspiel series for quality issues in the lauschi
catalog, a privacy-first kids audio player for the DACH region.

## Your role

A first AI (curate) has already classified every album in this series as
included or excluded, and episode numbers were extracted by deterministic
regex. You don't re-classify albums one by one. You **judge the
structure**: does this curation hang together as a coherent series, or
are there defects that should be fixed before it ships to families?

The user prompt carries:
1. A pre-computed structural analysis of the curation
2. The full lists of included and excluded albums

Use the analysis as evidence; don't recompute what's already there.

## Reading the analysis

- **title_clusters** groups titles by structural shape. One dominant
  cluster is healthy. Multiple clusters with distinct prefixes
  ("Junior - Folge n", "Gute-Nacht-Geschichten - Folge n", "Benjamin
  Minis - Folge n") are **structural evidence of sub-series mixed
  in**. Propose a split for each non-dominant cluster of 2+ albums.
  Sub-series belong in their own catalog entry even when they're
  part of the same franchise — kids navigating by episode number
  shouldn't see "Folge 5" point to three different stories. Don't
  rationalize this as "intentional editorial choice."
- **outliers** are titles whose shape appears once. Often box sets,
  specials, compilations, or unrelated content that slipped in.
- **duplicates_within_provider** is a real defect: same provider + same
  episode_num. Two album_ids appearing as the same episode means kids
  see the story twice. **Propose an override that excludes one** —
  default is to keep the older release; format variants
  (Kopfhörer-Hörspiel, "Neuaufnahme", remasters) get excluded since
  the regular version covers the same story. Use album_details to
  compare track listings if you're not sure which to keep.
- **cross_provider_coverage** shows asymmetry. Episodes missing on one
  provider are usually content rotation (the provider hasn't published
  it), not a curation defect — but verify with web_search if a long
  contiguous stretch is missing.
- **pattern_coverage** below ~90% with otherwise-clean titles signals a
  broken episode_pattern. Use update_episode_pattern to propose a fix.
- **gaps** lists missing episode numbers. Same caveat as
  cross_provider_coverage: usually content rotation, not a defect.
  Verify before flagging.
- **common_words** helps you confirm the series identity from titles.

## Tools

You have two flavors of tools: research (read-only, gather information)
and proposal (write, accumulate actions on the run state). All
proposals are made via tool calls — your final structured output
contains only verdicts and a short summary, never action lists.

### Research tools

- **album_details** (max 10): fetch track listings for ambiguous albums.
- **web_search** (max 5): research the series. Good queries:
  - `"Series Name" Hörspiel Episodenliste`
  - `site:hoerspiele.de "Series Name"`
  - `"Series Name" Junior` to confirm a sub-series exists
- **fetch_page** (max 3): drill into a search hit. hoerspiele.de
  carries authoritative episode lists for German Hörspiele.

### Proposal tools (each call records ONE action)

- **propose_override** (max 30): exclude or include one album. Each
  call records a single override on (album_id, provider, action,
  reason). Call repeatedly to propose multiple. Tool will refuse
  duplicate album_ids and unknown ones.
- **propose_split** (max 10 calls): move a group of albums to a new
  series entry. Multiple calls with the SAME ``new_series_id`` merge
  into one split — chunk a 50-album sub-series across 3-4 calls of
  ~15 ids each rather than packing one giant list. Tool validates
  ids against the curation.
- **add_album** (max 10): add a missing album discovered via web
  research. Requires ``evidence_url`` from a non-provider domain
  (hoerspiele.de etc.) and refuses if you haven't searched first.
- **propose_pattern_update** (max 3): record a new episode_pattern.
  Each pattern compiles, has exactly one capture group, and is tried
  in order at apply time.

If a tool returns an error message, fix the args and retry — the tool
gives concrete feedback. Don't keep retrying with the same args.

## Output

Your structured output has only TWO fields:

- **decisions**: a per-category verdict with one-sentence reasoning.
- **summary**: 1-3 sentence overall verdict on the curation, max 500
  chars. Don't repeat per-category reasoning, don't paste structured
  data — those go in decisions[*].reasoning and the action tools.

### decisions — pick exactly one verdict per category

- **decisions.duplicates** — within-provider episode-num collisions:
  - `resolved_via_overrides`: you called propose_override for the duplicates.
  - `no_within_provider_duplicates`: analysis shows none, no action.
  - `deferred_to_human`: defects exist but complex case, human decides.
- **decisions.sub_series** — distinct title clusters:
  - `splits_proposed`: you called propose_split for the sub-series.
  - `no_sub_series_mixed_in`: single coherent series.
  - `era_variants_kept`: multiple shapes but same numbering scheme
    across eras (Die drei ??? "n" + "folge n" both 1-200).
  - `deferred_to_human`.
- **decisions.gaps** — missing episode numbers:
  - `filled_via_add_album`: you called add_album for verifiable gaps.
  - `verified_content_rotation`: web search confirmed gaps are
    provider unavailability, not curation defects.
  - `no_gaps_present`.
  - `deferred_to_human`.
- **decisions.pattern** — episode_pattern correctness:
  - `pattern_updated`: you called propose_pattern_update.
  - `current_pattern_correct`: pattern_coverage already high.
  - `not_applicable_for_music`: this is a music artist.
  - `deferred_to_human`.
- **decisions.outliers** — singleton-shape titles:
  - `excluded_via_overrides`: you called propose_override for the outliers.
  - `legitimate_specials_kept`: standalone specials are fine to keep.
  - `no_outliers_found`.
  - `deferred_to_human`.
- **decisions.cross_provider** — Spotify/Apple coverage asymmetry:
  - `verified_content_rotation`: web search confirmed asymmetry is
    provider availability.
  - `balanced`: both providers carry the same set.
  - `single_provider_only`: only one provider configured.
  - `deferred_to_human`.

Each decision REQUIRES a ``reasoning`` string (max 350 chars) scoped
to that category. Concrete and specific.

## Rules

- Trust the structural analysis. It's deterministic; if it shows
  duplicates_within_provider entries or distinct title clusters,
  those are facts. Use the proposal tools to act on them.
- Verdicts must match the tools you called. If you say
  ``duplicates: resolved_via_overrides`` but never called
  propose_override, the assembler downgrades your verdict to
  ``deferred_to_human``. Pick honestly: actually call the tool, or
  pick a non-action verdict.
- Era variants stay together: when two clusters share a single
  coherent numbering scheme, pick ``sub_series: era_variants_kept``,
  do NOT call propose_split.
- Don't fill gaps with add_album unless web evidence confirms the
  episode is on the provider under a different artist account.
- ``deferred_to_human`` is the EXCEPTION, not the default. Use it
  only for genuine ambiguity that can't be resolved with the data on
  hand. Most curations should land all six verdicts on a definite
  state — action verdict + populated tool calls, or a non-action
  verdict like ``no_X_found`` / ``balanced`` / ``content_rotation``.
  Lean toward action: filtering out duplicates and bad content is
  the whole point of review. If you're 80% sure, propose; the
  verify step (4-eye check) catches over-reach.
- **Duplicates always get filtered.** When
  duplicates_within_provider has entries, you have two valid paths:
  (a) call propose_override to exclude one of each pair (default
  keeps the older release, format variants like Kopfhörer-Hörspiel
  get excluded), then verdict = ``resolved_via_overrides``; OR
  (b) when your propose_split calls move the duplicate-causing
  albums into separate series, the residual duplicates in the main
  series are 0 — verdict = ``no_within_provider_duplicates`` AND
  reasoning explicitly says "addressed by splits". Don't pick
  ``deferred_to_human`` for duplicates unless the data is genuinely
  ambiguous.
- **Cross-provider asymmetry**: gaps on one provider that are
  present on the other are usually content rotation (the provider
  hasn't published or has rotated it out). You don't need to
  web-verify every gap to pick ``verified_content_rotation`` —
  that verdict means "this asymmetry is consistent with normal
  provider availability, no curation defect." Pick it confidently
  when the asymmetry pattern looks like rotation. Web search only
  when something looks suspicious (e.g., one provider missing 50+
  consecutive episodes that are clearly published).
- Act, don't over-research. The structural analysis already tells
  you the cluster shapes, duplicate counts, gaps, and pattern
  coverage. Use research tools (web_search/fetch_page) only to
  disambiguate specific things — typically 0-3 calls. Most
  categories can be decided from the analysis alone. Get to the
  propose_X tools promptly.
"""


def _build_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, ReviewResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)

    # ToolOutput forces the model to emit ReviewResult as a function-call
    # payload (the OpenAI "tools" API) instead of free-form JSON in the
    # message content. Free-form JSON output is where the prose-leak
    # failure mode lives: the model can dump structured intent into the
    # `notes` string while leaving action arrays empty, and pydantic
    # accepts it because the output is technically valid. Tool-call mode
    # constrains the model to produce arguments that match the schema —
    # the same mechanism that makes verify reliable.
    agent: Agent[Deps, ReviewResult] = Agent(
        model,
        output_type=ToolOutput(
            ReviewResult,
            name="submit_review",
            description=(
                "Submit the review verdict. Populate the action lists "
                "(overrides, splits, added_albums, pattern_update) with any "
                "structural changes you propose. Use `notes` only for "
                "explanatory prose — never for describing actions you "
                "intend to take."
            ),
        ),
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        """Search the web for series info.

        Capped at Deps._MAX_SEARCHES calls per review run. Returns a list of
        ``{title, url, snippet}`` results. Good queries:
        - ``"Series Name" Hörspiel Episodenliste``
        - ``site:hoerspiele.de "Series Name"``
        """
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            return [{"error": f"Search limit reached (max {ctx.deps._MAX_SEARCHES})."}]
        ctx.deps._search_count += 1

        from lauschi_catalog.search import brave_search

        results = brave_search(query, count=5)
        n = len([r for r in results if "error" not in r])
        console.print(
            f"  [dim]🔍 web_search({query!r}) → {n} results "
            f"[{ctx.deps._search_count}/{ctx.deps._MAX_SEARCHES}][/]",
        )
        return results

    @agent.tool
    def fetch_page(ctx: RunContext[Deps], url: str) -> str:
        """Fetch a URL and return its text content.

        Capped at Deps._MAX_FETCHES calls per review run. Useful for
        drilling into hoerspiele.de series pages with authoritative
        episode listings.
        """
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            return f"Fetch limit reached (max {ctx.deps._MAX_FETCHES})."
        ctx.deps._fetch_count += 1

        from lauschi_catalog.search import fetch_page as _fetch

        content = _fetch(url, max_chars=4000)
        console.print(
            f"  [dim]📄 fetch_page({url[:60]}…) → {len(content)} chars "
            f"[{ctx.deps._fetch_count}/{ctx.deps._MAX_FETCHES}][/]",
        )
        return content

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], provider_name: str, album_id: str,
    ) -> dict:
        """Get full album details from a provider.

        Capped at Deps._MAX_DETAILS calls per review run. Cache hits don't
        count against the cap.
        """
        key = f"{provider_name}:{album_id}"
        if key in ctx.deps.seen_details:
            return ctx.deps.seen_details[key]

        if ctx.deps._details_count >= ctx.deps._MAX_DETAILS:
            return {"error": f"Album details limit reached (max {ctx.deps._MAX_DETAILS})."}
        ctx.deps._details_count += 1

        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return {"error": f"Provider {provider_name} not available"}
        album = target.album_details(album_id)
        if not album:
            return {"error": "Album not found"}
        result = {
            "id": album.id, "name": album.name, "provider": provider_name,
            "total_tracks": album.total_tracks, "label": album.label,
            "tracks": [{"name": t.name, "duration_ms": t.duration_ms} for t in album.tracks],
        }
        ctx.deps.seen_details[key] = result
        console.print(
            f"  [dim]📀 album_details({provider_name}:{album_id[:8]}…) "
            f"→ {album.total_tracks} tracks "
            f"[{ctx.deps._details_count}/{ctx.deps._MAX_DETAILS}][/]",
        )
        return result

    @agent.tool
    def add_album(
        ctx: RunContext[Deps],
        provider_name: str,
        album_id: str,
        evidence_url: str,
    ) -> str:
        """Add a missing album to the series, recovered from the provider.

        ``evidence_url`` must point to a search result or page that
        confirms this episode belongs to the series. The tool refuses
        when the URL is missing or no prior web_search/fetch_page has
        been run; this prevents the agent from inventing album_ids.

        Capped at Deps._MAX_ADDS. Duplicates and not-found album IDs do
        not count against the cap.
        """
        from lauschi_catalog.commands.review_validation import validate_add_evidence

        evidence_error = validate_add_evidence(ctx.deps, evidence_url)
        if evidence_error:
            return evidence_error

        existing = {a["album_id"] for a in ctx.deps.curation.get("albums", [])}
        if album_id in existing:
            console.print(f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → already exists[/]")
            return f"Already exists: {album_id}"

        target = next((p for p in ctx.deps.providers if p.name == provider_name), None)
        if not target:
            return f"Provider {provider_name} not available"

        album = target.album_details(album_id)
        if not album:
            console.print(f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → not found[/]")
            return f"Not found: {album_id}"

        if ctx.deps._add_count >= ctx.deps._MAX_ADDS:
            return f"Add limit reached (max {ctx.deps._MAX_ADDS})."
        ctx.deps._add_count += 1

        from lauschi_catalog.catalog.matcher import extract_episode
        pattern = ctx.deps.curation.get("episode_pattern")
        episode_num = extract_episode(pattern, album.name)

        new_album = {
            "album_id": album_id,
            "provider": provider_name,
            "include": True,
            "episode_num": episode_num,
            "title": album.name,
            "exclude_reason": None,
            "evidence_url": evidence_url,
        }
        ctx.deps.added_albums.append(new_album)
        ep_str = f" (episode {episode_num})" if episode_num else ""
        console.print(
            f"  [dim]➕ add_album({provider_name}:{album_id[:8]}…) → {album.name}{ep_str} "
            f"[{ctx.deps._add_count}/{ctx.deps._MAX_ADDS}][/]",
        )
        return f"Added: {album.name}{ep_str} (evidence: {evidence_url})"

    @agent.tool
    def propose_override(
        ctx: RunContext[Deps],
        album_id: str,
        provider: str,
        action: str,
        reason: str,
    ) -> str:
        """Propose excluding (or including) one album from the curation.

        Each call records ONE override on Deps. Call multiple times to
        propose multiple overrides — there is no batch form. The
        assembler reads the accumulated list at end of the run.

        Validates: album_id must already be in the curation; action must
        be 'exclude' or 'include'; reason must be non-empty; the same
        album_id can't be overridden twice in one review run.

        Capped at Deps._MAX_OVERRIDES.
        """
        if ctx.deps._override_count >= ctx.deps._MAX_OVERRIDES:
            return f"Override limit reached (max {ctx.deps._MAX_OVERRIDES})."

        if action not in ("exclude", "include"):
            return f"action must be 'exclude' or 'include', got {action!r}"
        if not (reason or "").strip():
            return "reason is required and must be non-empty"

        existing = {a["album_id"] for a in ctx.deps.curation.get("albums", [])}
        if album_id not in existing:
            return f"album_id {album_id!r} is not in this curation"

        for prior in ctx.deps.proposed_overrides:
            if prior["album_id"] == album_id:
                return (
                    f"Already proposed an override for {album_id} "
                    f"(action={prior['action']!r}). One per album per review."
                )

        ctx.deps._override_count += 1
        ctx.deps.proposed_overrides.append({
            "album_id": album_id,
            "provider": provider,
            "action": action,
            "reason": reason,
        })
        console.print(
            f"  [dim]🔄 propose_override({provider}:{album_id[:8]}…, {action}) "
            f"[{ctx.deps._override_count}/{ctx.deps._MAX_OVERRIDES}][/]",
        )
        return f"Override recorded: {action} {album_id}"

    @agent.tool
    def propose_split(
        ctx: RunContext[Deps],
        new_series_id: str,
        new_series_title: str,
        album_ids: list[str],
        provider: str,
        reason: str,
    ) -> str:
        """Propose moving a group of albums to a new series entry.

        Multiple calls with the SAME ``new_series_id`` are merged at
        assembly time — so for a sub-series with 50+ album_ids you can
        chunk it across 3-4 calls of ~15 ids each instead of trying to
        emit one giant list. Album ids are deduped; the first reason
        wins.

        Validates: new_series_id is snake_case; album_ids must all be
        in the curation; non-empty.

        Capped at Deps._MAX_SPLITS calls (each chunk counts).
        """
        import re as _re
        if ctx.deps._split_count >= ctx.deps._MAX_SPLITS:
            return f"Split limit reached (max {ctx.deps._MAX_SPLITS})."

        if not _re.fullmatch(r"[a-z][a-z0-9_]*", new_series_id):
            return (
                f"new_series_id must be snake_case [a-z][a-z0-9_]*, "
                f"got {new_series_id!r}"
            )
        if not (new_series_title or "").strip():
            return "new_series_title is required"
        if not album_ids:
            return "album_ids cannot be empty"
        if not (reason or "").strip():
            return "reason is required"

        existing = {a["album_id"] for a in ctx.deps.curation.get("albums", [])}
        unknown = [aid for aid in album_ids if aid not in existing]
        if unknown:
            return (
                f"album_ids not in curation: "
                f"{unknown[:5]}{'…' if len(unknown) > 5 else ''}"
            )

        ctx.deps._split_count += 1
        ctx.deps.proposed_splits.append({
            "new_series_id": new_series_id,
            "new_series_title": new_series_title,
            "album_ids": list(album_ids),
            "provider": provider,
            "reason": reason,
        })
        console.print(
            f"  [dim]✂️ propose_split({new_series_id}, {len(album_ids)} albums) "
            f"[{ctx.deps._split_count}/{ctx.deps._MAX_SPLITS}][/]",
        )
        return (
            f"Split chunk recorded: {new_series_id} ({len(album_ids)} albums). "
            f"Call again with same new_series_id to add more."
        )

    @agent.tool
    def propose_pattern_update(
        ctx: RunContext[Deps], patterns: list[str],
    ) -> str:
        """Propose a new episode_pattern.

        Each pattern must compile and have exactly one capture group.
        Patterns are tried in order at apply time. The latest call wins
        (calling again replaces the prior proposal). Save_review applies
        it deterministically after the run.

        Capped at Deps._MAX_PATTERN_UPDATES.
        """
        import re as _re
        if ctx.deps._pattern_count >= ctx.deps._MAX_PATTERN_UPDATES:
            return f"Pattern update limit reached (max {ctx.deps._MAX_PATTERN_UPDATES})."

        for p in patterns:
            try:
                c = _re.compile(p)
            except _re.error as e:
                return f"Invalid regex {p!r}: {e}"
            if c.groups != 1:
                return f"Pattern {p!r}: needs exactly 1 capture group, got {c.groups}"

        from lauschi_catalog.catalog.matcher import preview_episode_pattern

        candidate = patterns[0] if len(patterns) == 1 else patterns
        would_change = preview_episode_pattern(
            ctx.deps.curation.get("albums", []), candidate,
        )

        ctx.deps._pattern_count += 1
        ctx.deps.proposed_pattern_update = candidate
        console.print(
            f"  [dim]📝 propose_pattern_update → {candidate} "
            f"({would_change} would change) "
            f"[{ctx.deps._pattern_count}/{ctx.deps._MAX_PATTERN_UPDATES}][/]",
        )
        return (
            f"Pattern {candidate!r} recorded. Applying would re-extract "
            f"episode_num for {would_change} album(s)."
        )

    return agent


def _build_prompt(curation: dict) -> str:
    """Render the review prompt: structural analysis + full album lists.

    Verify uses the same shape so the agent sees a consistent picture across
    pipeline stages. Including the full lists inline lets us drop the
    ``show_series`` tool: there's nothing left for it to fetch.
    """
    title = curation.get("title", "?")
    series_id = curation.get("id", "?")
    pattern = curation.get("episode_pattern", "none")
    artist_ids = curation.get("provider_artist_ids", {})
    content_type = curation.get("content_type", "hoerspiel")
    analysis = analyze_series(curation)

    albums = curation.get("albums", [])
    review = curation.get("review", {})
    excluded_via_override = {
        o["album_id"]
        for o in review.get("overrides", [])
        if o["action"] == "exclude"
    }

    included = sorted(
        [
            a for a in albums
            if a.get("include") and a["album_id"] not in excluded_via_override
        ],
        key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
    )
    excluded = [a for a in albums if not a.get("include")]

    lines = [
        f"## Series: {title} (id: {series_id})",
        f"Content type: {content_type}",
        f"Episode pattern: {pattern}",
        f"Provider artist IDs: {artist_ids}",
        "",
    ]
    if content_type == "music":
        lines.extend([
            "### Music artist — different rules apply",
            "This curation is a children's MUSIC artist, not a Hörspiel"
            " series. Albums are standalone music releases. Do NOT propose"
            " excluding albums for being 'music singles' — that is the"
            " expected content here. Episode numbers, episode_pattern,"
            " gaps, and sub-series clustering are not relevant. Look only"
            " for: cross-provider inconsistencies (same album included on"
            " one provider but excluded on another), compilations vs"
            " original releases, and accidental Hörspiel/audiobook content"
            " mixed into a music artist.",
            "",
        ])
    lines.extend([
        "### Structural analysis",
        json.dumps(analysis, indent=2, ensure_ascii=False),
        "",
        f"### Included albums ({len(included)})",
    ])
    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        lines.append(
            f"  ✅ [{a.get('provider', '?')}] {ep_str}{a['title']} "
            f"[{a['album_id']}]",
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded[:30]:
        reason = a.get("exclude_reason", "")
        suffix = f" — {reason}" if reason else ""
        lines.append(
            f"  ❌ [{a.get('provider', '?')}] {a['title']} "
            f"[{a['album_id']}]{suffix}",
        )
    if len(excluded) > 30:
        lines.append(f"  … and {len(excluded) - 30} more")

    lines.append(
        "\nReview the structure. Use propose_override, propose_split, "
        "add_album, and propose_pattern_update to record any actions you "
        "decide on (one tool call per item). When done, return your "
        "structured output: decisions (one verdict + one-sentence "
        "reasoning per category) plus a 1-3 sentence summary. "
        "Use web_search and fetch_page when the analysis raises a "
        "question you can't answer from the data alone.",
    )
    return "\n".join(lines)


async def _run_review(
    curation: dict,
    providers: list[CatalogProvider],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 600,
) -> AssembledReview:
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/red]")
        raise SystemExit(1)

    agent = _build_agent(model_name, api_key)
    prompt = _build_prompt(curation)

    for attempt in range(_MAX_RETRIES):
        # Fresh deps each outer attempt so a prior failed attempt's
        # exhausted tool counters don't starve the next one.
        deps = Deps(providers=providers, curation=curation)
        try:
            async def _run():
                async with agent.iter(
                    prompt, deps=deps,
                    # request_limit needs to fit: research tool calls
                    # (~5-10) + action proposals (~5-15 propose_X calls)
                    # + final tool call for ReviewResult + reasoning
                    # turns + headroom for one inner retry. 60 covers
                    # observed BB-scale runs comfortably.
                    usage_limits=UsageLimits(request_limit=60),
                ) as run:
                    async for node in run:
                        if not hasattr(node, "model_response"):
                            continue
                        for part in node.model_response.parts:
                            text = getattr(part, "content", None)
                            if isinstance(text, str) and len(text.strip()) > 80:
                                kind = getattr(part, "part_kind", "")
                                if kind == "thinking":
                                    console.print(Panel(
                                        text.strip()[:500],
                                        border_style="dim", title="💭",
                                        padding=(0, 1),
                                    ))
                    return run.result.output

            result = await asyncio.wait_for(_run(), timeout=timeout)
            return assemble_review(result, deps)
        except Exception as e:
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            if attempt < _MAX_RETRIES - 1:
                console.print(f"[yellow]Attempt {attempt + 1} failed: {err}[/yellow]")
                await asyncio.sleep(_RETRY_DELAY)
            else:
                raise


def _merge_split_chunks(chunks: list[dict]) -> list[SplitProposal]:
    """Combine ``propose_split`` calls that share a ``new_series_id``.

    The agent can chunk a 50-album sub-series across multiple calls
    rather than emitting one nested array. This collapses those chunks
    into one SplitProposal per series, deduping album_ids and keeping
    the first-encountered title/provider/reason.
    """
    by_id: dict[str, dict] = {}
    for chunk in chunks:
        sid = chunk["new_series_id"]
        if sid not in by_id:
            by_id[sid] = {
                "new_series_id": sid,
                "new_series_title": chunk["new_series_title"],
                "album_ids": list(chunk["album_ids"]),
                "provider": chunk["provider"],
                "reason": chunk["reason"],
            }
        else:
            existing = by_id[sid]
            seen = set(existing["album_ids"])
            for aid in chunk["album_ids"]:
                if aid not in seen:
                    existing["album_ids"].append(aid)
                    seen.add(aid)
    return [SplitProposal(**v) for v in by_id.values()]


def assemble_review(result: ReviewResult, deps: Deps) -> AssembledReview:
    """Combine model output (decisions + summary) with deps tool-driven actions.

    The model emits only ``decisions`` and ``summary``. All action
    proposals — overrides, splits, added albums, pattern update —
    accumulate on Deps via tool calls during the run. This function
    pulls them together and applies the same consistency check the
    pydantic validator used to do (now at this layer where we have
    plain data, not pydantic models): if a decision claims an action
    was taken but the corresponding list is empty, the verdict is
    coerced to ``deferred_to_human`` with a marker on the reasoning.
    """
    overrides = [ReviewOverride(**o) for o in deps.proposed_overrides]
    splits = _merge_split_chunks(deps.proposed_splits)
    added_albums = [
        AddedAlbum(
            album_id=e["album_id"],
            provider=e["provider"],
            title=e["title"],
            episode_num=e.get("episode_num"),
            include=e.get("include", True),
            exclude_reason=e.get("exclude_reason"),
            evidence_url=e.get("evidence_url", ""),
        )
        for e in deps.added_albums
    ]
    pattern_update = deps.proposed_pattern_update

    decisions = result.decisions.model_copy(deep=True)
    coerced: list[str] = []

    if decisions.duplicates.verdict == DuplicatesVerdict.RESOLVED_VIA_OVERRIDES and not overrides:
        decisions.duplicates = DuplicatesDecision(
            verdict=DuplicatesVerdict.DEFERRED,
            reasoning=(decisions.duplicates.reasoning or "")[:200] + _AUTO_DOWNGRADE_SUFFIX,
        )
        coerced.append("duplicates")
    if decisions.sub_series.verdict == SubSeriesVerdict.SPLITS_PROPOSED and not splits:
        decisions.sub_series = SubSeriesDecision(
            verdict=SubSeriesVerdict.DEFERRED,
            reasoning=(decisions.sub_series.reasoning or "")[:200] + _AUTO_DOWNGRADE_SUFFIX,
        )
        coerced.append("sub_series")
    if decisions.gaps.verdict == GapsVerdict.FILLED_VIA_ADD_ALBUM and not added_albums:
        decisions.gaps = GapsDecision(
            verdict=GapsVerdict.DEFERRED,
            reasoning=(decisions.gaps.reasoning or "")[:200] + _AUTO_DOWNGRADE_SUFFIX,
        )
        coerced.append("gaps")
    if decisions.pattern.verdict == PatternVerdict.PATTERN_UPDATED and pattern_update is None:
        decisions.pattern = PatternDecision(
            verdict=PatternVerdict.DEFERRED,
            reasoning=(decisions.pattern.reasoning or "")[:200] + _AUTO_DOWNGRADE_SUFFIX,
        )
        coerced.append("pattern")
    if decisions.outliers.verdict == OutliersVerdict.EXCLUDED_VIA_OVERRIDES and not overrides:
        decisions.outliers = OutliersDecision(
            verdict=OutliersVerdict.DEFERRED,
            reasoning=(decisions.outliers.reasoning or "")[:200] + _AUTO_DOWNGRADE_SUFFIX,
        )
        coerced.append("outliers")

    if coerced:
        console.print(
            f"[yellow]⚠ Coerced inconsistent verdicts to "
            f"{_DEFERRED}: {', '.join(coerced)}[/yellow]",
        )

    return AssembledReview(
        overrides=overrides,
        splits=splits,
        added_albums=added_albums,
        pattern_update=pattern_update,
        decisions=decisions,
        summary=result.summary,
    )


def _needs_re_verification(review: AssembledReview) -> bool:
    """True when the review's findings require the verify step to re-run.

    Either a structural change was proposed, OR any category landed on
    ``deferred_to_human`` (agent-chosen or coerced). In both cases the
    prior 'approved' state is no longer trusted.
    """
    if (
        review.overrides
        or review.splits
        or review.added_albums
        or review.pattern_update
    ):
        return True
    d = review.decisions
    return any(
        getattr(d, cat).verdict == _DEFERRED
        for cat in (
            "duplicates", "sub_series", "gaps",
            "pattern", "outliers", "cross_provider",
        )
    )


def save_review(series_id: str, review: AssembledReview) -> Path:
    """Save an AssembledReview into the curation JSON.

    Updates the review block in place: overrides/splits/added_albums/
    pattern_update/decisions/summary/reviewed_at are replaced with this
    run's output. Any other fields humans or older pipeline stages may
    have added (e.g. ``reviewed_by``) are preserved.

    When the review proposes any change OR defers any category to
    human, the prior ``status`` and ``verification`` block are stale —
    reset to ``ai_reviewed`` so verify re-checks.
    """
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Curation file not found: {path}[/red]")
        raise SystemExit(1)

    data = json.loads(path.read_text())
    review_block = data.setdefault("review", {})
    review_block["overrides"] = [o.model_dump() for o in review.overrides]
    review_block["splits"] = [s.model_dump() for s in review.splits]
    review_block["added_albums"] = [a.model_dump() for a in review.added_albums]
    review_block["pattern_update"] = review.pattern_update
    review_block["decisions"] = review.decisions.model_dump()
    review_block["summary"] = review.summary
    # Old reviews carried a free-form ``notes`` string. Drop it on save
    # so curations don't mix old and new shapes.
    review_block.pop("notes", None)
    review_block["reviewed_at"] = datetime.now(UTC).isoformat()

    if _needs_re_verification(review):
        review_block["status"] = "ai_reviewed"
        review_block.pop("verification", None)

    # Merge added albums into the main list before re-extraction, so
    # they pick up the (possibly updated) pattern in the same pass.
    if review.added_albums:
        existing_ids = {a["album_id"] for a in data.get("albums", [])}
        for added in review.added_albums:
            if added.album_id not in existing_ids:
                data.setdefault("albums", []).append(added.model_dump())

    if review.pattern_update:
        from lauschi_catalog.catalog.matcher import apply_episode_pattern

        data["episode_pattern"] = review.pattern_update
        data["albums"] = apply_episode_pattern(
            data.get("albums", []), review.pattern_update,
        )

    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Review all curated series")
@click.option("--force", is_flag=True, help="Re-review even if already approved or ai_verified")
@click.option("--model", default=_DEFAULT_MODEL)
@click.option("--timeout", default=600, help="Per-series timeout in seconds (default 10 min). Big series with many splits genuinely take 5+ min.")
@click.option("--provider", "-p", type=click.Choice(["spotify", "apple_music", "all"]), default="all")
def review(
    series_id: str | None,
    run_all: bool,
    force: bool,
    model: str,
    timeout: int,
    provider: str,
):
    """AI-review a curated series for quality issues."""
    from lauschi_catalog.providers.apple_music import AppleMusicProvider
    from lauschi_catalog.providers.spotify import SpotifyProvider

    if not series_id and not run_all:
        console.print("[red]Provide a series ID or use --all[/red]")
        raise SystemExit(1)

    providers: list[CatalogProvider] = []
    if provider in ("spotify", "all"):
        try:
            providers.append(SpotifyProvider())
        except SystemExit:
            console.print("[yellow]Spotify credentials not set, skipping[/yellow]")
    if provider in ("apple_music", "all"):
        try:
            providers.append(AppleMusicProvider())
        except FileNotFoundError:
            console.print("[yellow]Apple Music key not found, skipping[/yellow]")

    if run_all:
        paths = sorted(CURATION_DIR.glob("*.json"))
    else:
        paths = [CURATION_DIR / f"{series_id}.json"]

    skipped = 0
    for path in paths:
        if not path.exists():
            console.print(f"[yellow]Skipping {path.stem}: no curation file[/yellow]")
            continue

        curation = json.loads(path.read_text())

        # Don't clobber already-approved reviews. The verify step locks a
        # curation when both AIs agree; re-running review would replace
        # that human-trusted state with fresh AI output, including any
        # human-added overrides. Use --force to override (e.g., after a
        # re-curation pulled in new episodes).
        existing_status = curation.get("review", {}).get("status")
        if not force and existing_status in ("approved", "ai_verified"):
            console.print(
                f"[dim]Skipping {path.stem} (already {existing_status}; "
                f"use --force to re-review)[/dim]",
            )
            skipped += 1
            continue

        console.print(f"\n[bold]Reviewing {curation.get('title', path.stem)}...[/bold]")

        review = asyncio.run(
            _run_review(curation, providers, model_name=model, timeout=timeout),
        )

        # Always persist the review block — the per-category decisions
        # and summary are valuable provenance for human auditors even
        # when no actions were proposed.
        save_path = save_review(path.stem, review)
        console.print(
            f"  {len(review.overrides)} overrides, {len(review.splits)} splits, "
            f"{len(review.added_albums)} added"
            + (", pattern_update" if review.pattern_update else ""),
        )
        console.print(f"  [green]Saved to {save_path}[/green]")

        # One-line per-category roll-up so the human can spot
        # escalations at a glance without opening the JSON.
        d = review.decisions
        verdicts = (
            f"  dup:{d.duplicates.verdict} | sub:{d.sub_series.verdict} | "
            f"gap:{d.gaps.verdict} | pat:{d.pattern.verdict} | "
            f"out:{d.outliers.verdict} | xprov:{d.cross_provider.verdict}"
        )
        console.print(f"  [dim]{verdicts}[/dim]")
        if review.summary:
            console.print(f"  Summary: {review.summary}")
