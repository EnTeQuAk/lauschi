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
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path

import click

from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext, ToolOutput
from lauschi_catalog._opencode import build_opencode_model
from pydantic_ai.usage import UsageLimits
from rich.console import Console
from rich.markup import escape
from rich.panel import Panel

from lauschi_catalog.catalog.analysis import analyze_series, effective_albums
from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.catalog.lifecycle import review_is_stale
from lauschi_catalog.catalog.matcher import compute_pattern_coverage
from lauschi_catalog.providers import CatalogProvider
from lauschi_catalog.retry import is_retryable

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"

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


class RemovalProposal(BaseModel):
    """Agent's verdict that this catalog entry has no legitimate
    streaming content and should be removed from series.yaml.

    Stored in the curation JSON's review block. Apply does NOT
    auto-remove — surfaces via log-summary for human review, and
    a future ``catalog-apply-removals`` command handles batched
    removal with confirmation.
    """
    reason: str
    # Set by the orchestrator at save time, not by the agent.
    proposed_by: str = ""
    proposed_at: str = ""


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
    # Splits move the colliding albums to separate series, so the
    # residual within-provider duplicates in this curation drop to
    # zero. Distinct from NONE_FOUND because the analysis DID surface
    # collisions — they're just resolved indirectly by the splits.
    ADDRESSED_BY_SPLITS = "addressed_by_splits"
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
    # Agent's "remove this entry entirely" verdict. Persisted in the
    # curation JSON; apply never auto-removes. log-summary surfaces
    # it as an ATTENTION-level flag so a human can review and act.
    removal_proposal: RemovalProposal | None = None


# ── Dependencies ───────────────────────────────────────────────────────────

@dataclass
class Deps:
    """Per-run state. Tools accumulate proposed actions here; the
    assembler reads them back at the end of the run.

    Three flavors of fields:
    - ``providers`` and ``curation`` are inputs (set on construction).
    - ``proposed_overrides`` / ``proposed_splits`` / ``added_albums`` /
      ``proposed_pattern_update`` are populated by the action tools.
    - ``_*_count`` track tool-call usage. External-cost tools also
      have ``_MAX_*`` caps (see below); local-action tools rely on
      per-tool dedup + the agent run's request_limit instead.
    """
    providers: list[CatalogProvider]
    curation: dict
    proposed_overrides: list[dict] = field(default_factory=list)
    proposed_splits: list[dict] = field(default_factory=list)
    added_albums: list[dict] = field(default_factory=list)
    proposed_pattern_update: str | list[str] | None = field(default=None, init=False)
    # Latest-wins: subsequent propose_removal calls replace the prior
    # proposal. Stored as a dict ({"reason": str}) so the tool
    # signature stays minimal — the model + timestamp metadata is
    # added by assemble_review where we know which model is running.
    proposed_removal: dict | None = field(default=None, init=False)
    seen_details: dict[str, dict] = field(default_factory=dict)
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _details_count: int = field(default=0, init=False)
    _override_count: int = field(default=0, init=False)
    _split_count: int = field(default=0, init=False)
    _add_count: int = field(default=0, init=False)
    _pattern_count: int = field(default=0, init=False)
    # Caps split by cost profile. External-cost tools (web_search,
    # fetch_page, album_details, and add_album which calls
    # album_details internally) stay tightly capped — those map to
    # real $/quota.
    #
    # Local-action tools (override / overrides_batch / split /
    # pattern_update) carry no external cost and don't need
    # per-tool caps. They're bounded by:
    #  - per-album_id dedup (an album can be overridden once)
    #  - same-new_series_id chunk merging (split chunks coalesce)
    #  - latest-wins replacement (pattern_update)
    #  - the agent run's request_limit (the global ceiling that
    #    catches any actual runaway loop)
    _MAX_SEARCHES: int = 5
    _MAX_FETCHES: int = 3
    _MAX_DETAILS: int = 10
    _MAX_ADDS: int = 10


def _try_record_override(
    deps: Deps,
    album_id: str,
    action: str,
    reason: str,
    *,
    provider: str,
) -> str | None:
    """Append an override to ``deps.proposed_overrides`` if eligible.

    Shared by ``propose_override`` (single) and
    ``propose_overrides_batch`` so dedup + shape rules can't drift
    between them. Returns ``None`` on success, or a short reason
    string when the album was skipped:

    - ``"unknown"`` — album_id isn't in this curation
    - ``"duplicate"`` — album_id was already overridden in this run

    Action / reason validation lives at the tool boundary because the
    two tools surface those errors differently (single returns an
    error string; batch wouldn't want to fail the whole batch).
    """
    existing = {a["album_id"] for a in deps.curation.get("albums", [])}
    if album_id not in existing:
        return "unknown"
    for prior in deps.proposed_overrides:
        if prior["album_id"] == album_id:
            return "duplicate"
    deps._override_count += 1
    deps.proposed_overrides.append({
        "album_id": album_id,
        "provider": provider,
        "action": action,
        "reason": reason,
    })
    return None


_SYSTEM_PROMPT = """\
You review curated Hörspiel series for quality issues in the lauschi
catalog (kids audio player, DACH region).

A first AI (curate) classified each album include/exclude and
extracted episode numbers by deterministic regex. Don't re-classify
albums. **Judge the structure**: sub-series mixed in, within-provider
duplicates, broken patterns, outliers, cross-provider gaps.

The user prompt carries the structural analysis (clusters, dupes,
gaps, coverage) and the full album lists. Trust the analysis as facts.

## Tools

Research (read-only):
- ``album_details``: track listings for an album_id
- ``web_search``: research the series; ``site:hoerspiele.de`` is gold
- ``fetch_page``: drill into a search hit

Proposals:
- ``propose_override``: exclude or include ONE album with a reason
- ``propose_overrides_batch``: exclude or include MANY albums at
  once with a shared reason. Use this when dedup'ing format
  variants or excluding a whole class (e.g., Kopfhörer-Hörspiel
  duplicates, English releases) instead of emitting many identical
  propose_override calls
- ``propose_split``: move albums to a new series; multiple calls with
  the same ``new_series_id`` merge — chunk large lists (e.g., 50
  album_ids across 3-4 calls of ~15 each) instead of packing them
- ``add_album``: add a missing episode (needs evidence_url from a
  non-provider domain; refuses without prior research)
- ``propose_pattern_update``: propose a new episode_pattern regex
- ``propose_removal``: recommend deleting this catalog entry
  entirely. Use ONLY when there's no legitimate streaming content
  to support the entry (artist doesn't exist on the providers, all
  matches are misattributed, series is CD/Audible-only). Not for
  "needs re-curate" or "a few wrong inclusions" — use overrides for
  those. Apply never auto-removes; the proposal surfaces for human
  review via log-summary.

If a tool returns an error, fix the args — don't keep retrying.

## Output

ReviewResult has two fields:
- ``decisions``: 6 categorical verdicts each with one-sentence
  reasoning (max 350 chars per reasoning).
- ``summary``: 1-3 sentence overall verdict (max 500 chars).

Action lists are NOT in your output — they're collected from your
tool calls and merged in by the assembler.

## Rules

- **Verdict must match what you did.** If you say ``splits_proposed``
  but never called ``propose_split``, the assembler downgrades to
  ``deferred_to_human``. Same for the other action verdicts.
- **``deferred_to_human`` is the EXCEPTION.** Lean toward action.
  Most categories land on a definite state (action verdict, or
  non-action like ``no_X_found`` / ``balanced`` / ``content_rotation``).
  The verify step (4-eye check) catches over-reach.
- **Duplicates always get filtered.** Either propose_override per
  pair (or propose_overrides_batch when a whole CLASS is being
  excluded — e.g., all Kopfhörer-Hörspiel format variants share
  one reason) → verdict ``resolved_via_overrides``; OR your splits
  move the colliding albums to separate series → verdict
  ``addressed_by_splits`` (requires non-empty splits list).
- **Era variants stay together.** Two clusters sharing one numbering
  scheme (Die drei ??? "n" + "folge n", both 1-200) are the same
  series across eras → ``sub_series: era_variants_kept``. Don't split.
- **Outliers are usually noise.** Singleton-shape titles are box
  sets, specials, music albums, soundtracks, or "Sonderedition"
  releases that slipped through curate. Default action: call
  propose_override to exclude. Pick ``legitimate_specials_kept``
  only when the outlier is a real standalone Hörspiel worth
  keeping (e.g., a film tie-in that fans expect).
- **Cross-provider asymmetry** is usually content rotation. Pick
  ``verified_content_rotation`` confidently from the analysis.
  Web-search only if 50+ consecutive episodes are missing on one
  provider while clearly published.
- **add_album** only for episodes web evidence confirms exist on
  the provider under a different artist account. Evidence URL must
  not be a provider URL (circular).
- **Music vs Hörspiel**: the ``content_type`` field in the user
  prompt tells you. For music: ``pattern: not_applicable_for_music``
  and skip episode-number-based actions.
- **Respect prior review state.** If the user prompt has a "Prior
  review state" section, those overrides/splits/pattern_updates were
  set deliberately (often by a human or a prior verified review).
  Don't undo them or re-propose the same actions. Diverge only with
  a strong, explicit reason in your reasoning.
- **Be terse.** Don't paste album_ids or JSON into reasoning/summary
  text fields — that data lives in the action tools.
"""


def _build_agent(
    model_name: str, api_key: str,
) -> Agent[Deps, ReviewResult]:
    model = build_opencode_model(model_name, api_key)

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

        Returns: ``{id, name, provider, release_date, total_tracks,
        label, artists, tracks}``. ``release_date`` (ISO YYYY-MM-DD or
        YYYY) helps decide original-vs-remaster overrides and spot
        compilation re-releases. ``artists`` flags wrong-artist
        matches that slipped through curation.

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
            "release_date": album.release_date,
            "total_tracks": album.total_tracks,
            "label": album.label,
            "artists": album.artists,
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

        Each call records ONE override on Deps. Use propose_overrides_batch
        when you need to apply the same exclude/include + reason to many
        album_ids (e.g., dedup'ing format variants).

        Validates: album_id must already be in the curation; action must
        be 'exclude' or 'include'; reason must be non-empty; the same
        album_id can't be overridden twice in one review run.

        No per-tool cap — bounded naturally by per-album_id dedup
        (each album can only be overridden once) and by the agent
        run's request_limit. The whole point of this change was that
        an arbitrary override cap was cutting off legitimate work
        on series with many format-variant duplicates.
        """
        if action not in ("exclude", "include"):
            return f"action must be 'exclude' or 'include', got {action!r}"
        if not (reason or "").strip():
            return "reason is required and must be non-empty"

        skip = _try_record_override(
            ctx.deps, album_id, action, reason, provider=provider,
        )
        if skip == "unknown":
            return f"album_id {album_id!r} is not in this curation"
        if skip == "duplicate":
            prior_action = next(
                o["action"] for o in ctx.deps.proposed_overrides
                if o["album_id"] == album_id
            )
            return (
                f"Already proposed an override for {album_id} "
                f"(action={prior_action!r}). One per album per review."
            )

        console.print(
            f"  [dim]🔄 propose_override({provider}:{album_id[:8]}…, {action}) "
            f"[{ctx.deps._override_count}][/]",
        )
        return f"Override recorded: {action} {album_id}"

    @agent.tool
    def propose_overrides_batch(
        ctx: RunContext[Deps],
        album_ids: list[str],
        action: str,
        reason: str,
    ) -> str:
        """Propose the same override (exclude/include) on many albums at once.

        Use when you'd otherwise emit dozens of identical
        propose_override calls — e.g., a series carries three
        coexisting numbering formats and you need to exclude 30+
        format-variant duplicates with the same justification. One
        tool call instead of thirty saves request_limit budget and
        keeps the reasoning trace readable.

        Each album_id is validated independently. Already-overridden
        IDs and IDs not in the curation are skipped (not errored) —
        the call records what it can and reports the rest in the
        return string. The provider is looked up from the curation
        per album so the recorded override carries accurate
        provenance even when the batch spans providers.
        """
        if action not in ("exclude", "include"):
            return f"action must be 'exclude' or 'include', got {action!r}"
        if not (reason or "").strip():
            return "reason is required and must be non-empty"
        if not album_ids:
            return "album_ids cannot be empty"

        albums = ctx.deps.curation.get("albums", [])
        provider_lookup = {
            a["album_id"]: a.get("provider", "?") for a in albums
        }

        recorded: list[str] = []
        skipped_unknown: list[str] = []
        skipped_dup: list[str] = []

        for aid in album_ids:
            skip = _try_record_override(
                ctx.deps,
                aid,
                action,
                reason,
                provider=provider_lookup.get(aid, "?"),
            )
            if skip == "unknown":
                skipped_unknown.append(aid)
            elif skip == "duplicate":
                skipped_dup.append(aid)
            else:
                recorded.append(aid)

        console.print(
            f"  [dim]🔄 propose_overrides_batch({len(album_ids)} → "
            f"{action}) → {len(recorded)} recorded "
            f"[{ctx.deps._override_count}][/]",
        )

        parts = [f"Recorded {len(recorded)} {action}(s)"]
        if skipped_unknown:
            parts.append(
                f"skipped {len(skipped_unknown)} unknown album_id(s)"
            )
        if skipped_dup:
            parts.append(
                f"skipped {len(skipped_dup)} already-overridden"
            )
        return ". ".join(parts) + "."

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

        No per-tool cap — chunks merge by new_series_id at assembly,
        so even many calls collapse cleanly. Bounded by request_limit.
        """
        import re as _re

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
            f"[{ctx.deps._split_count}][/]",
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

        Each pattern must compile, have exactly one capture group, AND
        capture an integer when matched (`int(group)` must succeed).
        The proposal is REJECTED if it matches fewer than half of the
        included titles — patterns that only match a couple albums in
        a larger series are cosmetic and produce fragile metadata
        (alles_steht_kopf's '(\\d+)' was the motivating case: it
        captured the "2" in "Inside Out 2" but had no anchor and
        would mis-fire on the next album with any digit in its title).

        If the series has no systematic episode numbering, do NOT
        propose a pattern — leave it as None and the framework will
        sort albums by release_date downstream.

        Latest call wins (idempotent replacement). Bounded by
        request_limit, no per-tool cap.
        """
        for p in patterns:
            try:
                c = re.compile(p)
            except re.error as e:
                return f"Invalid regex {p!r}: {e}"
            if c.groups != 1:
                return f"Pattern {p!r}: needs exactly 1 capture group, got {c.groups}"

        candidate = patterns[0] if len(patterns) == 1 else patterns

        # Numeric + coverage check against the included titles. Same
        # contract the curate batch agent enforces (curate.py), kept
        # symmetric so a pattern that would survive the batch path
        # also survives review's late corrections.
        included_titles = [
            a["title"] for a in ctx.deps.curation.get("albums", [])
            if a.get("include") and a.get("title")
        ]
        if included_titles:
            check = compute_pattern_coverage(included_titles, patterns)
            if "error" in check:
                return check["error"]
            if check["matched"] == 0:
                non_numeric = check.get("non_numeric_capture_samples") or []
                if non_numeric:
                    sample = non_numeric[0]
                    return (
                        f"Pattern {candidate!r}: matches titles but "
                        f"capture group 1 isn't numeric — captured "
                        f"{sample['captured']!r} from "
                        f"{sample['title']!r}. Episode numbers must "
                        f"be int-parseable; tighten group 1 to (\\d+) "
                        f"or similar. If the series has no episode "
                        f"numbers, leave the pattern as None."
                    )
                return (
                    f"Pattern {candidate!r}: doesn't match any of "
                    f"{len(included_titles)} included titles. If the "
                    f"series has no episode numbering, leave the "
                    f"pattern as None — release_date sort handles "
                    f"order in the UI."
                )
            if check["coverage"] < 0.5:
                return (
                    f"Pattern {candidate!r}: matches only "
                    f"{check['matched']}/{check['total']} "
                    f"({check['coverage']:.0%}) of titles. A pattern "
                    f"that covers less than half the series is "
                    f"cosmetic and produces fragile metadata. If only "
                    f"a few albums carry numbers (e.g. sequels), "
                    f"leave the pattern as None — release_date sort "
                    f"handles ordering."
                )

        # Display "would change" count for diagnostic continuity with
        # prior tool output. Computed against the FULL album list
        # (not just included) since pattern_update applies broadly.
        from lauschi_catalog.catalog.matcher import preview_episode_pattern

        would_change = preview_episode_pattern(
            ctx.deps.curation.get("albums", []), candidate,
        )

        ctx.deps._pattern_count += 1
        ctx.deps.proposed_pattern_update = candidate
        console.print(
            f"  [dim]📝 propose_pattern_update → {candidate} "
            f"({would_change} would change) "
            f"[{ctx.deps._pattern_count}][/]",
        )
        return (
            f"Pattern {candidate!r} recorded. Applying would re-extract "
            f"episode_num for {would_change} album(s)."
        )

    @agent.tool
    def propose_removal(
        ctx: RunContext[Deps], reason: str,
    ) -> str:
        """Recommend that this entire catalog entry be removed.

        Use when, after looking at the data, you conclude there's no
        legitimate streaming content to support this entry — for example:

        - Provider search returns nothing recognizable as this series
          (artist doesn't exist on Spotify/Apple Music; only on
          Audible, YouTube, or CD-only).
        - All included albums are misattributed — the provider picked
          a different artist who happens to share part of the name
          (e.g. "cocomelon" matched a Japanese pop group).
        - The "series" turned out to be a label or compilation banner,
          not a coherent show or artist users would search for.
        - The catalog entry duplicates another entry with better
          coverage and there's nothing distinct here worth keeping.

        Do NOT propose removal for entries that just need a re-curate
        or have a handful of wrong inclusions — use propose_override
        (single or batch) for those. Small but legitimate series
        (e.g. a 2-album classic Hörspiel) are not bullshit; keep
        them.

        Apply does NOT auto-remove. The proposal lands in the
        curation JSON and surfaces in catalog-log-summary as an
        ATTENTION-level flag; a human reviews and either confirms
        the removal (deletes from series.yaml) or rejects it.

        Latest call wins (idempotent replacement). One reason field
        — be specific so the human can act on it without re-reading
        the whole curation.
        """
        if not (reason or "").strip():
            return "reason is required — explain WHY this entry should be removed"
        if len(reason.strip()) < 20:
            return (
                "reason is too short — provide enough context that "
                "a human can act on the removal without re-running "
                "discovery (mention what's missing/wrong)"
            )
        ctx.deps.proposed_removal = {"reason": reason.strip()}
        console.print(
            f"  [dim]🗑️ propose_removal → {reason.strip()[:80]}…[/]",
        )
        return (
            f"Removal proposal recorded. The series will surface in "
            f"catalog-log-summary as ATTENTION; no automatic deletion."
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
        # Numbered first by episode_num, unnumbered fall back to
        # release_date so the agent sees chronological order
        # rather than alphabetical for named-episode series.
        key=lambda a: (
            a.get("episode_num") is None, a.get("episode_num"),
            a.get("release_date") or "",
            a["title"],
        ),
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
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        lines.append(
            f"  ✅ [{a.get('provider', '?')}] {ep_str}{a['title']}"
            f"{rel_str} [{a['album_id']}]",
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded[:30]:
        reason = a.get("exclude_reason", "")
        suffix = f" — {reason}" if reason else ""
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        lines.append(
            f"  ❌ [{a.get('provider', '?')}] {a['title']}"
            f"{rel_str} [{a['album_id']}]{suffix}",
        )
    if len(excluded) > 30:
        lines.append(f"  … and {len(excluded) - 30} more")

    # Prior review state: any overrides/splits/pattern_update/summary a
    # previous review (or human edit) put in place. The agent should
    # respect these as deliberate decisions and only revise with strong
    # reason. Without this section the agent works from a sanitized view
    # and may unwittingly contradict prior intent.
    prior_lines = _format_prior_review_state(review)
    if prior_lines:
        lines.append("")
        lines.extend(prior_lines)

    lines.append(
        "\nReview the structure. Use propose_override (single) or "
        "propose_overrides_batch (many albums sharing one reason), "
        "propose_split, add_album, and propose_pattern_update to record "
        "the actions you decide on. When done, return your structured "
        "output: decisions (one verdict + one-sentence reasoning per "
        "category) plus a 1-3 sentence summary. Use web_search and "
        "fetch_page when the analysis raises a question you can't "
        "answer from the data alone.",
    )
    return "\n".join(lines)


def _format_prior_review_state(review: dict) -> list[str]:
    """Render the prior review block for the agent's prompt.

    Returns an empty list if there's nothing prior worth showing —
    fresh curations skip this section entirely. Otherwise the agent
    sees what overrides, splits, pattern updates, and summary were
    set previously, so it can make decisions consistent with them.

    Per-decision reasonings are intentionally elided: too verbose
    and the new run produces its own. Status is included because it
    tells the agent why this review is happening (escalated → prior
    issues, approved + --force → human re-asked, etc.).
    """
    overrides = review.get("overrides", []) or []
    splits = review.get("splits", []) or []
    pattern_update = review.get("pattern_update")
    prior_summary = (review.get("summary") or "").strip()
    status = review.get("status")
    reviewed_by = review.get("reviewed_by")

    if not (overrides or splits or pattern_update or prior_summary):
        return []

    lines = ["### Prior review state"]
    bits = []
    if status:
        bits.append(f"status={status}")
    if reviewed_by:
        bits.append(f"reviewed_by={reviewed_by}")
    if bits:
        lines.append("  " + ", ".join(bits))

    if overrides:
        lines.append(f"  Overrides ({len(overrides)}):")
        for o in overrides[:10]:
            action = o.get("action", "?")
            reason = (o.get("reason") or "").strip()[:120]
            lines.append(
                f"    • [{o.get('provider', '?')}] {action} {o.get('album_id', '?')}"
                f"{f' — {reason}' if reason else ''}",
            )
        if len(overrides) > 10:
            lines.append(f"    … and {len(overrides) - 10} more")

    if splits:
        lines.append(f"  Splits ({len(splits)}):")
        for s in splits:
            n = len(s.get("album_ids", []))
            lines.append(
                f"    • {s.get('new_series_id', '?')} ({n} albums) — "
                f"{(s.get('reason') or '').strip()[:100]}",
            )

    if pattern_update:
        lines.append(f"  Pattern update: {pattern_update}")

    if prior_summary:
        lines.append(f"  Prior summary: {prior_summary[:300]}")

    lines.append(
        "  These are deliberate decisions. Respect them: don't propose "
        "actions that contradict prior overrides/splits unless you have "
        "strong, explicit reason — and explain that reason.",
    )
    return lines


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
                    # request_limit covers: research tool calls (~5-10),
                    # action proposals (overrides via batch + splits +
                    # adds + pattern), the final ReviewResult tool call,
                    # reasoning turns, and headroom for one inner retry.
                    # Bumped to 120 because Hui-Buh-class series with
                    # multiple coexisting numbering formats can need
                    # 30+ exclusions; 60 was leaving them cut off
                    # mid-cleanup.
                    usage_limits=UsageLimits(request_limit=120),
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
            return assemble_review(result, deps, model_name=model_name)
        except asyncio.TimeoutError:
            # Same reasoning as verify: a 600s budget that timed out
            # already burned the budget; retrying just doubles it.
            raise
        except Exception as e:
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            # Don't retry auth/validation/4xx — they won't fix
            # themselves and a retry costs another _RETRY_DELAY.
            if is_retryable(e) and attempt < _MAX_RETRIES - 1:
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

    Filters non-string album_ids defensively. propose_split's tool
    schema declares ``list[str]`` but pydantic-ai has been known to
    pass through stray ``None``/``int`` values when the model emits
    malformed JSON; downstream code (apply, the Flutter app) treats
    these as opaque ids and would corrupt the catalog.
    """
    def _str_ids(values: list) -> list[str]:
        return [v for v in values if isinstance(v, str) and v]

    by_id: dict[str, dict] = {}
    for chunk in chunks:
        sid = chunk["new_series_id"]
        if sid not in by_id:
            by_id[sid] = {
                "new_series_id": sid,
                "new_series_title": chunk["new_series_title"],
                "album_ids": _str_ids(chunk["album_ids"]),
                "provider": chunk["provider"],
                "reason": chunk["reason"],
            }
        else:
            existing = by_id[sid]
            seen = set(existing["album_ids"])
            for aid in _str_ids(chunk["album_ids"]):
                if aid not in seen:
                    existing["album_ids"].append(aid)
                    seen.add(aid)
    return [SplitProposal(**v) for v in by_id.values()]


def assemble_review(
    result: ReviewResult, deps: Deps, model_name: str = "",
) -> AssembledReview:
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
    if decisions.duplicates.verdict == DuplicatesVerdict.ADDRESSED_BY_SPLITS and not splits:
        # Claiming splits resolved the duplicates only makes sense if
        # splits actually exist. Without them, fall back to deferred.
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

    removal = None
    if deps.proposed_removal:
        removal = RemovalProposal(
            reason=deps.proposed_removal["reason"],
            proposed_by=model_name or "",
            proposed_at=datetime.now(UTC).isoformat(),
        )

    return AssembledReview(
        overrides=overrides,
        splits=splits,
        added_albums=added_albums,
        pattern_update=pattern_update,
        decisions=decisions,
        summary=result.summary,
        removal_proposal=removal,
    )


def _needs_re_verification(review: AssembledReview) -> bool:
    """True when the review's findings require the verify step to re-run.

    Either a structural change was proposed, OR any category landed on
    ``deferred_to_human`` (agent-chosen or coerced). In both cases the
    prior 'approved' state is no longer trusted.

    Uses each category's own ``Verdict.DEFERRED`` member rather than a
    shared string. StrEnum equality with the underlying value works,
    but explicit per-category constants are friendlier to type
    checkers and survive a category being renamed without silently
    skipping it.
    """
    if (
        review.overrides
        or review.splits
        or review.added_albums
        or review.pattern_update
        or review.removal_proposal
    ):
        return True
    d = review.decisions
    return (
        d.duplicates.verdict == DuplicatesVerdict.DEFERRED
        or d.sub_series.verdict == SubSeriesVerdict.DEFERRED
        or d.gaps.verdict == GapsVerdict.DEFERRED
        or d.pattern.verdict == PatternVerdict.DEFERRED
        or d.outliers.verdict == OutliersVerdict.DEFERRED
        or d.cross_provider.verdict == CrossProviderVerdict.DEFERRED
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
    if review.removal_proposal:
        review_block["removal_proposal"] = review.removal_proposal.model_dump()
    else:
        # Latest-wins: clearing the proposal on a re-review where the
        # agent didn't repeat it. Without this, a stale proposal
        # could outlive the situation that triggered it.
        review_block.pop("removal_proposal", None)
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

    canonicalize(data)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
    return path


@click.command()
@click.argument("series_id", required=False)
@click.option("--all", "run_all", is_flag=True, help="Review all curated series")
@click.option("--force", is_flag=True, help="Re-review even if already approved or ai_verified")
@click.option("--model", default=_DEFAULT_MODEL)
@click.option(
    "--timeout", default=1200,
    help="Per-series timeout in seconds (default 20 min). Big series "
    "with many overrides and pattern revisions take 10+ min; the old "
    "600 default was timing out series like Pumuckl mid-run.",
)
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
    succeeded = 0
    failed = 0
    failed_ids: list[str] = []
    for path in paths:
        if not path.exists():
            console.print(f"[yellow]Skipping {path.stem}: no curation file[/yellow]")
            continue

        curation = json.loads(path.read_text())

        # Skip approved curations unless either:
        #  - --force was passed, OR
        #  - curate has run since the last review (status is stale).
        # The staleness check is what makes ``catalog-pipeline`` self-
        # healing: a re-curate refreshes data, review re-runs everywhere
        # the prior approval no longer covers, no manual --force needed.
        existing_status = curation.get("review", {}).get("status")
        if (
            not force
            and existing_status in ("approved", "ai_verified")
            and not review_is_stale(curation)
        ):
            console.print(
                f"[dim]Skipping {path.stem} (already {existing_status}; "
                f"use --force to re-review)[/dim]",
            )
            skipped += 1
            continue

        console.print(f"\n[bold]Reviewing {curation.get('title', path.stem)}...[/bold]")

        try:
            review = asyncio.run(
                _run_review(curation, providers, model_name=model, timeout=timeout),
            )
        except Exception as e:
            # One stuck series shouldn't kill the whole --all run.
            # Log, count as failed, and move on. The per-series JSON
            # stays untouched — its prior review state (if any) is
            # preserved, and the user can re-run just this id later.
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            # escape() so a regex or other bracket-containing content
            # in the error string can't be parsed as Rich markup —
            # that crash bypassed the per-series resilience this
            # except block was supposed to provide.
            console.print(
                f"[red]Failed to review {path.stem}: {escape(err[:300])}[/red]",
            )
            failed += 1
            failed_ids.append(path.stem)
            continue

        # Always persist the review block — the per-category decisions
        # and summary are valuable provenance for human auditors even
        # when no actions were proposed.
        save_path = save_review(path.stem, review)
        console.print(
            f"  {len(review.overrides)} overrides, {len(review.splits)} splits, "
            f"{len(review.added_albums)} added"
            + (", pattern_update" if review.pattern_update else "")
            + (", removal_proposed" if review.removal_proposal else ""),
        )
        if review.removal_proposal:
            # Loud one-liner so the human notices it scrolling past in
            # an --all run and can decide whether to act. The full
            # reason is in the JSON; log-summary will surface it again
            # at ATTENTION health level.
            console.print(
                f"  [yellow]🗑️ Removal proposed:[/yellow] "
                f"[dim]{review.removal_proposal.reason[:120]}[/dim]",
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
        succeeded += 1

    if run_all:
        console.print(
            f"\n[bold]Review results:[/bold] {succeeded} reviewed, "
            f"{skipped} skipped, {failed} failed",
        )
        if failed_ids:
            console.print(f"[red]Failed: {', '.join(failed_ids)}[/red]")
