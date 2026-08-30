"""Library functions for the 4-eye audit pipeline.

Reads a curated series and asks a different model to independently
review. Returns structured results via callbacks for progress.

Pipeline: curated -> audited -> approved / escalated
"""

from __future__ import annotations

import asyncio
import json
import os
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field
from pydantic_ai import Agent, ModelRetry, RunContext, ToolOutput
from pydantic_ai.usage import RunUsage

from lauschi_catalog._opencode import (
    build_model,
    get_model_profile,
    get_model_settings,
)
from lauschi_catalog.agent_deps import AgentDeps, Progress, _noop
from lauschi_catalog.agent_hooks import build_progress_hooks
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.catalog.analysis import analyze_series, group_by_shape
from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.catalog.facts import (
    EraBoundaryProposal,
    KnownGapProposal,
    SubSeriesProposal,
    fact_provenance,
)
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.lifecycle import audit_is_stale, review_block
from lauschi_catalog.catalog.lint_ops import (
    compress_runs,
    critical_issues,
    lint_curation,
)
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.prompts import load_curate_skill
from lauschi_catalog.rate_limit import run_with_rate_limit_retry
from lauschi_catalog.run import run_agent, run_with_attempts, usage_summary

_DEFAULT_MODEL = "minimax-m2.7"
_MAX_RETRIES = 12
_RETRY_DELAY = 10

AuditRoute = Literal["one_shot", "chunked"]

Provider = Literal["spotify", "apple_music"]

# -- Output models --


class AuditOverride(BaseModel):
    album_id: str
    provider: Provider
    action: Literal["exclude", "include"]
    reason: str


class AuditFactUpdate(BaseModel):
    mode: Literal["merge", "replace"] = "merge"
    era_boundaries: list[EraBoundaryProposal] = Field(default_factory=list)
    known_gaps: list[KnownGapProposal] = Field(default_factory=list)
    sub_series: list[SubSeriesProposal] = Field(default_factory=list)


class AuditResult(BaseModel):
    approve: bool = Field(
        description="True if the curation is sound overall. "
        "False when significant problems need human attention. "
        "Use concerns and overrides for targeted fixes even when "
        "approving; approval with minor overrides is normal.",
    )
    concerns: list[str] = Field(
        default_factory=list,
        description="Issues found, even if still approving. "
        "Each concern is a human-readable sentence. More than 5 "
        "concerns automatically escalates regardless of approve.",
    )
    overrides: list[AuditOverride] = Field(default_factory=list)
    fact_updates: list[AuditFactUpdate] = Field(default_factory=list)


# -- Agent --


@dataclass
class AuditDeps(AgentDeps):
    series_id: str = ""
    curation: dict = field(default_factory=dict)
    lint_issues: list[str] = field(default_factory=list)
    #: requests and tokens across every chunk of this audit
    usage: RunUsage = field(default_factory=RunUsage)
    # Query -> how many times search_included_albums has answered it. A
    # repeated identical query returns an identical answer, so past the
    # allowance the tool says so instead of re-computing; see the guard.
    _search_counts: dict[str, int] = field(default_factory=dict, init=False)


def _build_audit_agent(
    model,
    *,
    model_name: str = "",
    content_type: str = "hoerspiel",
    discography_span_years: int | None = None,
    on_progress: Progress = _noop,
):
    skill_instructions = load_curate_skill(
        phase="audit",
        content_type=content_type,
        discography_span_years=discography_span_years,
    )
    profile = get_model_profile(model_name)
    agent: Agent[AuditDeps, AuditResult] = Agent(
        model,
        output_type=ToolOutput(
            AuditResult,
            name="submit_audit",
            description=(
                "Submit your audit verdict. Use overrides and fact_updates "
                "for targeted fixes; concerns for anything worth flagging."
            ),
        ),
        instructions=skill_instructions,
        model_settings=get_model_settings("audit", model_name),
        retries={"tools": 2, "output": 2},
        toolsets=[build_agent_tools()],
        capabilities=[build_progress_hooks()],
    )

    @agent.tool
    def search_included_albums(
        ctx: RunContext[AuditDeps],
        query: str,
    ) -> list[dict[str, str]]:
        """Search included albums by title keyword (case-insensitive).

        Use this to find album_ids when writing overrides or verifying
        sub_series membership.
        """
        q = query.lower()
        albums = ctx.deps.curation.get("albums", [])
        results = [
            {
                "album_id": a["album_id"],
                "provider": a.get("provider", "?"),
                "title": a["title"],
            }
            for a in albums
            if a.get("include") and q in a["title"].lower()
        ]
        seen = ctx.deps._search_counts.get(q, 0) + 1
        ctx.deps._search_counts[q] = seen
        if seen > profile.search_repeat_allowance:
            ctx.deps.on_progress(
                f"  search_included_albums({query!r}) -> repeated {seen}x, refused",
            )
            raise ModelRetry(
                f"You already searched {query!r} {seen - 1} times and got the "
                f"same {len(results)} hit(s) each time; the result cannot change "
                "within this audit. Use those hits, or submit your verdict."
            )
        ctx.deps.on_progress(
            f"  search_included_albums({query!r}) -> {len(results)} hits",
        )
        return results

    @agent.tool
    def lint_current_curation(ctx: RunContext[AuditDeps]) -> list[str]:
        """Run deterministic structural checks on the current curation."""
        issues = lint_curation(ctx.deps.curation)
        ctx.deps.on_progress(f"  lint_current_curation -> {len(issues)} issues")
        return issues

    return agent


# -- Prompt builder --
#
# The one-shot prompt and the chunked audit's overview are built from the
# same section builders, so the two cannot drift apart. build_prompt's
# output is pinned byte-for-byte by a test: it is what the size boundary
# was probed against and what most series are audited with.


def _sorted_included(albums: list[dict]) -> list[dict]:
    return sorted(
        [a for a in albums if a.get("include")],
        key=lambda a: (
            a.get("episode_num") is None,
            a.get("episode_num"),
            a.get("release_date") or "",
            a["title"],
        ),
    )


def _header_lines(curation: dict) -> list[str]:
    lines = [
        f"## Series: {curation.get('title', '?')} (id: {curation.get('id', '?')})",
        f"Episode pattern: {curation.get('episode_pattern', 'none')}",
    ]
    split_from = curation.get("split_from")
    if split_from:
        lines.append(
            f"Note: This series was split from '{split_from}'. "
            "The albums were moved from the parent's curation, not re-discovered."
        )
    return lines


def _included_line(a: dict) -> str:
    ep = a.get("episode_num")
    ep_str = f"Ep {ep}: " if ep is not None else ""
    rel = a.get("release_date") or ""
    rel_str = f" ({rel})" if rel else ""
    conf = a.get("confidence", "high")
    conf_tag = f" [{conf}]" if conf != "high" else ""
    notes = a.get("notes", "")
    notes_str = f" -- notes: {notes}" if notes and conf != "high" else ""
    return f"  [{a.get('provider', '?')}:{a['album_id']}] {ep_str}{a['title']}{rel_str}{conf_tag}{notes_str}"


def _excluded_line(a: dict) -> str:
    reason = a.get("exclude_reason", "")
    rel = a.get("release_date") or ""
    rel_str = f" ({rel})" if rel else ""
    reason_str = f" -- {reason}" if reason else ""
    notes = a.get("notes", "")
    notes_str = f" (notes: {notes})" if notes else ""
    return f"  [{a.get('provider', '?')}:{a['album_id']}] {a['title']}{rel_str}{reason_str}{notes_str}"


def _album_line(a: dict) -> str:
    return _included_line(a) if a.get("include") else _excluded_line(a)


def _album_lines(albums: list[dict]) -> list[str]:
    included = _sorted_included(albums)
    excluded = [a for a in albums if not a.get("include")]
    lines = ["", f"### Included albums ({len(included)})"]
    lines.extend(_included_line(a) for a in included)
    lines.append(f"\n### Excluded albums ({len(excluded)})")
    lines.extend(_excluded_line(a) for a in excluded)
    return lines


def _coverage_lines(albums: list[dict]) -> list[str]:
    """Per-provider included episodes as compressed runs, plus what each
    provider is excluding and why. This is the whole-series picture the
    chunked audit carries into every chunk in place of the album list."""
    eps_by_provider: dict[str, set[int]] = {}
    reasons_by_provider: dict[str, dict[str, int]] = {}
    for a in albums:
        prov = a.get("provider", "?")
        if a.get("include"):
            ep = a.get("episode_num")
            if ep is not None:
                eps_by_provider.setdefault(prov, set()).add(ep)
        else:
            key = (a.get("exclude_reason") or "unspecified").split(":")[0].strip()
            counts = reasons_by_provider.setdefault(prov, {})
            counts[key] = counts.get(key, 0) + 1
    lines = ["", "### Coverage"]
    for prov in sorted(eps_by_provider):
        eps = sorted(eps_by_provider[prov])
        lines.append(f"  {prov} included episodes ({len(eps)}): {compress_runs(eps)}")
    for prov in sorted(reasons_by_provider):
        top = sorted(reasons_by_provider[prov].items(), key=lambda kv: (-kv[1], kv[0]))
        summary = ", ".join(f"{r} {n}" for r, n in top)
        lines.append(f"  {prov} excluded: {summary}")
    return lines


def _facts_lines(curation: dict) -> list[str]:
    facts = curation.get("series_facts")
    if not facts:
        return []
    lines = ["\n### Series facts"]
    for e in facts.get("era_boundaries", []):
        aud = e.get("audited_by")
        status = f" [audited by {aud}]" if aud else " [unaudited]"
        lines.append(
            f"  Era: {e.get('label', '?')} ({e.get('release_date_range', '?')}){status}"
        )
    for g in facts.get("known_gaps", []):
        aud = g.get("audited_by")
        status = f" [audited by {aud}]" if aud else " [unaudited]"
        num = g.get("number", "?")
        rend = g.get("range_end")
        ep_label = f"{num}-{rend}" if rend else str(num)
        lines.append(
            f"  Known gap: episode {ep_label} -- {g.get('reason', '')}{status}"
        )
    for s in facts.get("sub_series", []):
        aud = s.get("audited_by")
        status = f" [audited by {aud}]" if aud else " [unaudited]"
        aids = s.get("album_ids", [])
        ids_str = f" (album_ids: {aids})" if aids else " (no album_ids)"
        lines.append(
            f"  Sub-series: {s.get('label', '?')} -- {s.get('reason', '')}{ids_str}{status}"
        )
    return lines


def _analysis_lines(curation: dict, *, max_clusters: int | None = None) -> list[str]:
    """Deterministic structural summary.

    ``max_clusters`` caps the title-cluster listing. Clusters are sorted
    by size, so the cap keeps the big shapes and folds the long tail of
    one-off titles into a single count line. The one-shot prompt leaves
    it unlimited (it has room); the overview caps it, because on a
    fragmented discography (stephen_janetzko: 174 clusters) listing every
    shape with examples is the album dump under another name.
    """
    analysis = analyze_series(curation)
    parts: list[str] = []
    if analysis.get("gaps"):
        parts.append(
            f"  Gaps: {len(analysis['gaps'])} missing episodes ({analysis['gaps']})"
        )
    dupes = analysis.get("duplicates_within_provider") or []
    if dupes:
        by_prov: dict[str, list[int]] = {}
        for d in dupes:
            by_prov.setdefault(d["provider"], []).append(d["episode_num"])
        for prov, eps in by_prov.items():
            parts.append(f"  Duplicates on {prov}: episodes {sorted(eps)}")
    xpc = analysis.get("cross_provider_coverage") or {}
    for prov, missing_eps in (xpc.get("missing_per_provider") or {}).items():
        if missing_eps:
            parts.append(f"  {prov} missing: {missing_eps}")
    clusters = analysis.get("title_clusters") or []
    if clusters:
        parts.append(f"  Title clusters ({len(clusters)} groups):")
        shown = clusters if max_clusters is None else clusters[:max_clusters]
        for c in shown:
            examples = ", ".join(c["examples"][:3])
            parts.append(f"    {c['shape']!r} ({c['count']} albums): {examples}")
        rest = clusters[len(shown) :]
        if rest:
            parts.append(
                f"    ... and {len(rest)} smaller shapes covering "
                f"{sum(c['count'] for c in rest)} albums"
            )
    pc = analysis.get("pattern_coverage")
    if isinstance(pc, dict):
        parts.append(f"  Pattern coverage: {pc['percentage']}%")
    if not parts:
        return []
    return ["\n### Structural analysis (deterministic)", *parts]


def _lint_lines(lint_issues: list[str]) -> list[str]:
    if not lint_issues:
        return []
    return [
        f"\n### Lint findings ({len(lint_issues)})",
        "Each finding below is a data-driven structural warning. "
        "For each one: fix it (override/fact_update), record as a "
        "concern, or explain why it's a false positive.",
        *[f"  {issue}" for issue in lint_issues],
    ]


# Title clusters shown in the overview before the tail is folded into one
# count line. Clusters are size-sorted, so this keeps every shape that
# describes a real sub-line and drops only the one-off titles, which the
# chunked audit sees in full inside their own packed chunk anyway.
_OVERVIEW_MAX_CLUSTERS = 15

_PROMPT_FOOTER = (
    "\nAudit the above. Flag genuine errors, propose targeted fixes, "
    "and approve when sound."
)


def build_prompt(curation: dict, lint_issues: list[str]) -> str:
    """The one-shot audit prompt: the whole series, every album listed."""
    albums = curation.get("albums", [])
    lines = [
        *_header_lines(curation),
        *_album_lines(albums),
        *_facts_lines(curation),
        *_analysis_lines(curation),
        *_lint_lines(lint_issues),
        _PROMPT_FOOTER,
    ]
    return "\n".join(lines)


def build_overview(curation: dict, lint_issues: list[str]) -> str:
    """The whole-series picture without the album list.

    Carried into every chunk of a chunked audit so each judgment is made
    with the total story in view: per-provider coverage as runs, what is
    excluded and why, the series facts, the deterministic structural
    analysis, and the lint findings. It shares every section with
    build_prompt except the album lines, which the model pulls on demand
    through its tools instead.
    """
    albums = curation.get("albums", [])
    lines = [
        *_header_lines(curation),
        *_coverage_lines(albums),
        *_facts_lines(curation),
        *_analysis_lines(curation, max_clusters=_OVERVIEW_MAX_CLUSTERS),
        *_lint_lines(lint_issues),
    ]
    return "\n".join(lines)


# -- Chunk planner --
#
# Only the four series whose one-shot prompt is past the model profile's
# one_shot_max_tokens are chunked. A chunk is a small one-shot audit: the
# overview plus a subset of albums, and it must itself fit the one-shot
# limit. Albums are grouped so the judgment each chunk is asked for stays
# possible:
#
# - a title cluster that fits is one chunk, included and excluded members
#   together, so a split line (Kartoffelbrei parts 1-4 in, 5-11 out) is
#   seen whole;
# - a cluster too large to fit (a main line of hundreds of 'Folge N') is
#   subdivided by episode number, in order; a homogeneous numbered line
#   is "more of the same" and the overview already holds the range facts;
# - clusters too small to stand alone are packed together up to the
#   budget, which puts the outliers and one-offs side by side.
#
# Every album lands in exactly one chunk. Nothing is sampled or skipped.


@dataclass
class Chunk:
    label: str
    albums: list[dict]


# Per-chunk framing (the "Albums in this chunk" header, the rolling
# summary of earlier chunks, the closing instruction) that the budget
# must leave room for on top of the overview and the album lines.
_CHUNK_FRAMING_TOKENS = 600

# Size a chunk fills toward. The model profile's one_shot_max_tokens is
# the hard cap a chunk may never exceed, but a chunk filled to the cap is
# a slightly smaller copy of the prompt that failed. The audit's
# comfortable working size is far lower: across the 275 series the
# one-shot handles, the prompt median is 1,163 tokens and the 90th
# percentile 6,035. Chunks fill to that 90th percentile, so each is a
# judgment the model is known to make well, and stop before the cap on
# the rare oversized album.
_CHUNK_TARGET_TOKENS = 6_000

# Members a title cluster needs to be a sub-line that gets its own chunk.
# On the chunked series, two-member clusters are cross-provider pairs of
# one album (wieso_weshalb_warum: 163 of 163; stephen_janetzko: 255 of
# 264), which must pack. Real sub-lines start at eight (Bibi: Kampf um
# Kartoffelbrei 20, Kurzgeschichte 22, Kurzhörspiele 24). Six sits in
# the observed gap.
_SUB_LINE_MIN_MEMBERS = 6


def _album_cost(a: dict) -> int:
    """Size of this album's line in the same units as the budget.

    Measured by rendering the real line, because per-album cost varies
    several-fold across series (short titles vs long notes) and a fixed
    estimate would let a chunk overflow.
    """
    return prompt_size(_album_line(a)) + 1


def _episode_key(a: dict) -> tuple[int, int, str]:
    ep = a.get("episode_num")
    return (ep is None, ep if ep is not None else 0, a.get("title", ""))


def _split_by_range(
    shape: str,
    members: list[dict],
    target: int,
    max_included: int,
) -> list[Chunk]:
    """Subdivide one oversized cluster into episode-ordered chunks that
    each fill toward ``target`` and never exceed ``max_included`` albums.
    """
    ordered = sorted(members, key=_episode_key)
    chunks: list[Chunk] = []
    cur: list[dict] = []
    cur_cost = 0
    for a in ordered:
        cost = _album_cost(a)
        if cur and (cur_cost + cost > target or len(cur) >= max_included):
            chunks.append(Chunk(label=_range_label(shape, cur), albums=cur))
            cur, cur_cost = [], 0
        cur.append(a)
        cur_cost += cost
    if cur:
        chunks.append(Chunk(label=_range_label(shape, cur), albums=cur))
    return chunks


def _range_label(shape: str, albums: list[dict]) -> str:
    eps = [a["episode_num"] for a in albums if a.get("episode_num") is not None]
    if eps:
        return f"{shape} episodes {min(eps)}-{max(eps)}"
    return f"{shape} (unnumbered)"


def plan_chunks(
    curation: dict,
    lint_issues: list[str],
    *,
    model_name: str = _DEFAULT_MODEL,
) -> list[Chunk]:
    """Group a chunked series' albums into chunks that each fit the
    one-shot limit alongside the overview. Pure; no model call."""
    profile = get_model_profile(model_name)
    albums = curation.get("albums", [])
    overview_cost = prompt_size(build_overview(curation, lint_issues))
    fixed = overview_cost + _CHUNK_FRAMING_TOKENS
    cap = profile.one_shot_max_tokens - fixed
    if cap <= 0:
        raise ValueError(
            f"overview alone ({overview_cost} tokens) leaves no room for albums "
            f"under one_shot_max_tokens={profile.one_shot_max_tokens}"
        )
    # what a chunk fills toward; never above what fits under the cap
    budget = min(_CHUNK_TARGET_TOKENS - fixed, cap)
    if budget <= 0:
        budget = cap

    by_shape = group_by_shape(albums)
    # largest clusters first, so the big sub-lines get their own chunks
    # and the tail of small shapes is what gets packed
    ordered = sorted(by_shape.items(), key=lambda kv: (-len(kv[1]), kv[0]))

    chunks: list[Chunk] = []
    pack: list[dict] = []
    pack_shapes: list[str] = []
    pack_cost = 0

    def flush_pack() -> None:
        nonlocal pack, pack_shapes, pack_cost
        if pack:
            chunks.append(
                Chunk(
                    label=f"{len(pack_shapes)} small title groups",
                    albums=pack,
                )
            )
        pack, pack_shapes, pack_cost = [], [], 0

    for shape, members in ordered:
        cost = sum(_album_cost(a) for a in members)
        if cost > budget:
            flush_pack()
            chunks.extend(
                _split_by_range(shape, members, budget, profile.chunk_max_included)
            )
        elif len(members) >= _SUB_LINE_MIN_MEMBERS:
            # a real sub-line: judged whole, in its own chunk
            flush_pack()
            if len(members) > profile.chunk_max_included:
                chunks.extend(
                    _split_by_range(shape, members, budget, profile.chunk_max_included)
                )
            else:
                chunks.append(Chunk(label=shape, albums=list(members)))
        else:
            if pack and (
                pack_cost + cost > budget or len(pack) >= profile.chunk_max_included
            ):
                flush_pack()
            pack.extend(members)
            pack_shapes.append(shape)
            pack_cost += cost
    flush_pack()
    return chunks


def prompt_size(prompt: str) -> int:
    """Estimate a prompt's size in tokens as ``len(prompt) // 4``.

    Deliberately the same crude measure the one-shot boundary was probed
    with, so the model profile's one_shot_max_tokens keeps meaning what
    the probes established. A real tokenizer would be more accurate and
    would silently invalidate that boundary.
    """
    return len(prompt) // 4


def audit_route(
    curation: dict,
    lint_issues: list[str],
    *,
    model_name: str = _DEFAULT_MODEL,
) -> AuditRoute:
    """Decide whether a series gets the one-shot audit or the chunked one.

    Pure and free: it builds the prompt the one-shot audit would send and
    measures it. No model call is spent on the decision. One-shot is the
    default because a model that sees the whole series at once gives the
    best judgment; chunking is paid for only where the prompt is past the
    size the one-shot audit has been shown to handle.
    """
    profile = get_model_profile(model_name)
    size = prompt_size(build_prompt(curation, lint_issues))
    return "one_shot" if size <= profile.one_shot_max_tokens else "chunked"


# -- Core audit --


@dataclass
class _PreparedAudit:
    curation: dict
    lint_issues: list[str]
    agent: Agent[AuditDeps, AuditResult]
    deps: AuditDeps
    model_name: str = ""


def _prepare_audit(
    series_id: str,
    *,
    model_name: str,
    force: bool,
    providers: list | None,
    on_progress: Progress,
) -> _PreparedAudit | None:
    """Everything both audit paths share before the model runs: load,
    skip checks, lint, agent and deps. Returns None when there is nothing
    to audit (and has already said why)."""
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        on_progress("OPENCODE_API_KEY not set")
        return None

    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        on_progress(f"Not found: {path}")
        return None

    curation = json.loads(path.read_text())

    review = review_block(curation)
    status = review.get("status")
    stale = audit_is_stale(curation)
    if not force and not stale:
        if status in ("approved", "audited"):
            on_progress(f"Skipping {series_id} (already {status})")
            return None
        if status == "rejected":
            on_progress(f"Skipping {series_id} (rejected)")
            return None
    if stale:
        on_progress(f"  Re-auditing {series_id} (audit stale after re-curate)")

    lint_issues = lint_curation(curation)
    if lint_issues:
        on_progress(f"  Lint: {len(lint_issues)} issues")
        for issue in lint_issues:
            on_progress(f"    - {issue}")

    content_type = curation.get("content_type", "hoerspiel")
    albums = curation.get("albums", [])
    years = [
        int(str(rd)[:4])
        for a in albums
        if (rd := a.get("release_date")) and len(str(rd)) >= 4 and str(rd)[:4].isdigit()
    ]
    discography_span_years = (max(years) - min(years)) if len(years) >= 2 else None

    model = build_model(model_name, api_key)
    agent = _build_audit_agent(
        model,
        model_name=model_name,
        content_type=content_type,
        discography_span_years=discography_span_years,
        on_progress=on_progress,
    )
    deps = AuditDeps(
        series_id=series_id,
        curation=curation,
        lint_issues=lint_issues,
        providers=providers or [],
        on_progress=on_progress,
    )
    return _PreparedAudit(
        curation=curation,
        lint_issues=lint_issues,
        agent=agent,
        deps=deps,
        model_name=model_name,
    )


async def _run_audit_prompt(
    prepared: _PreparedAudit,
    prompt: str,
    *,
    phase: str,
    timeout: int,
    on_progress: Progress,
) -> AuditResult:
    profile = get_model_profile(prepared.model_name)
    return await run_with_rate_limit_retry(
        lambda: asyncio.wait_for(
            run_agent(
                prepared.agent,
                prompt,
                prepared.deps,
                request_limit=profile.request_limit,
                tally=prepared.deps.usage,
            ),
            timeout=timeout,
        ),
        phase=phase,
        max_retries=_MAX_RETRIES,
        base_delay=float(_RETRY_DELAY),
        max_delay=300.0,
        retry_timeout=False,
        on_progress=on_progress,
    )


# -- Chunked audit --


def _rolling_summary(partials: list[AuditResult]) -> list[str]:
    """What earlier chunks already decided, carried into the next chunk so
    it stays consistent with them. Same idea as curate's batch summary."""
    overrides = [o for r in partials for o in r.overrides]
    facts = [u for r in partials for u in r.fact_updates]
    if not overrides and not facts:
        return []
    lines = ["", "### Decisions from earlier chunks of this audit"]
    for o in overrides:
        lines.append(f"  {o.action} {o.provider}:{o.album_id} -- {o.reason}")
    for u in facts:
        n = len(u.era_boundaries) + len(u.known_gaps) + len(u.sub_series)
        lines.append(f"  proposed {n} fact update(s)")
    lines.append(
        "Do not contradict these. Extend them only if this chunk shows something new."
    )
    return lines


def _chunk_prompt(
    overview: str,
    chunk: Chunk,
    index: int,
    total: int,
    partials: list[AuditResult],
) -> str:
    """One chunk's prompt: the whole-series overview, what earlier chunks
    decided, this chunk's albums, and what is being asked."""
    included = _sorted_included(chunk.albums)
    excluded = [a for a in chunk.albums if not a.get("include")]
    lines = [
        overview,
        "",
        f"### This chunk ({index} of {total}): {chunk.label}",
        "This series is too large to audit in one request, so it is audited in "
        "chunks. The overview above is the whole series; the albums below are "
        "the only ones this chunk decides. Judge them against the overview. "
        "Use search_included_albums and get_album_details for any album "
        "outside this chunk you need to see.",
        "",
        f"#### Included in this chunk ({len(included)})",
        *[_included_line(a) for a in included],
        f"\n#### Excluded in this chunk ({len(excluded)})",
        *[_excluded_line(a) for a in excluded],
        *_rolling_summary(partials),
        "",
        "Audit the albums in this chunk. Propose overrides only for them. "
        "Propose fact updates in merge mode only: you see one chunk, so never "
        "replace the series facts. Record concerns for anything worth human "
        "attention, and approve when this chunk is sound.",
    ]
    return "\n".join(lines)


def merge_results(partials: list[AuditResult]) -> AuditResult:
    """Fold per-chunk results into one verdict without losing a finding
    or silently resolving a disagreement.

    - The same album overridden by two chunks with different actions is a
      contradiction. Neither override is applied; the conflict becomes a
      concern and the audit does not approve, so a human decides.
    - Fact updates are forced to merge mode. A chunk sees one slice; a
      replace from it would wipe facts other chunks or earlier audits
      established.
    - Concerns are deduplicated first, so a finding every chunk repeats
      (the same known gap) does not escalate on volume alone.
    """
    approve = all(r.approve for r in partials) if partials else False
    concerns: list[str] = []
    seen_concerns: set[str] = set()
    for r in partials:
        for c in r.concerns:
            if c not in seen_concerns:
                seen_concerns.add(c)
                concerns.append(c)

    by_album: dict[tuple[str, str], list[AuditOverride]] = {}
    for r in partials:
        for o in r.overrides:
            by_album.setdefault((o.provider, o.album_id), []).append(o)
    overrides: list[AuditOverride] = []
    for (prov, aid), group in by_album.items():
        actions = {o.action for o in group}
        if len(actions) == 1:
            overrides.append(group[0])
            continue
        approve = False
        concerns.append(
            f"[chunk_conflict] {prov}:{aid} was overridden both ways by different "
            f"chunks ({'; '.join(f'{o.action}: {o.reason}' for o in group)}); "
            "neither applied, needs a human decision"
        )

    fact_updates: list[AuditFactUpdate] = []
    for r in partials:
        for u in r.fact_updates:
            if u.mode == "replace":
                concerns.append(
                    "[chunk_facts] a chunk proposed replacing the series facts; "
                    "applied as a merge instead, since a chunk sees one slice"
                )
                u = u.model_copy(update={"mode": "merge"})
            fact_updates.append(u)

    return AuditResult(
        approve=approve,
        concerns=concerns,
        overrides=overrides,
        fact_updates=fact_updates,
    )


# Attempts per audit call (one-shot series or single chunk) before the
# series fails. A call fails on its own, independent of size: MiniMax
# M2.7 at low effort spent its whole output budget reasoning on a
# 30-album chunk, a 25-album chunk and one-shot Die Playmos (2026-08-30)
# after passing larger prompts. With 17-20 chunks per series, a per-call
# failure rate of a few percent made series failure near certain when
# one failed call ended the series. Benjamin Blümchen and Die Playmos
# both passed on their first fresh attempt.
_AUDIT_ATTEMPTS = 3


async def _audit_chunked(
    prepared: _PreparedAudit,
    series_id: str,
    *,
    timeout: int,
    on_progress: Progress,
) -> AuditResult:
    overview = build_overview(prepared.curation, prepared.lint_issues)
    chunks = plan_chunks(
        prepared.curation, prepared.lint_issues, model_name=prepared.model_name
    )
    on_progress(
        f"  Chunked audit: {len(prepared.curation.get('albums', []))} albums in "
        f"{len(chunks)} chunks (overview {prompt_size(overview)} tokens)"
    )
    partials: list[AuditResult] = []
    for i, chunk in enumerate(chunks, 1):
        on_progress(
            f"  Chunk {i}/{len(chunks)}: {chunk.label} ({len(chunk.albums)} albums)"
        )
        # Search-repeat allowance is per chunk, not across the whole series.
        prepared.deps._search_counts = {}
        prompt = _chunk_prompt(overview, chunk, i, len(chunks), partials)
        result = await run_with_attempts(
            lambda p=prompt, i=i: _run_audit_prompt(
                prepared,
                p,
                phase=f"audit {series_id} chunk {i}/{len(chunks)}",
                timeout=timeout,
                on_progress=on_progress,
            ),
            attempts=_AUDIT_ATTEMPTS,
            label=f"chunk {i}",
            on_progress=on_progress,
        )
        on_progress(
            f"    -> {'approve' if result.approve else 'disapprove'}, "
            f"{len(result.overrides)} overrides, {len(result.concerns)} concerns"
        )
        partials.append(result)
    return merge_results(partials)


async def audit_one(
    series_id: str,
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 600,
    force: bool = False,
    providers: list | None = None,
    on_progress: Progress = _noop,
    usage: RunUsage | None = None,
) -> AuditResult | None:
    """``usage``, when given, accumulates the requests and tokens of
    every model call this audit makes."""
    prepared = _prepare_audit(
        series_id,
        model_name=model_name,
        force=force,
        providers=providers,
        on_progress=on_progress,
    )
    if prepared is None:
        return None
    if usage is not None:
        prepared.deps.usage = usage

    route = audit_route(
        prepared.curation, prepared.lint_issues, model_name=prepared.model_name
    )
    if route == "chunked":
        return await _audit_chunked(
            prepared, series_id, timeout=timeout, on_progress=on_progress
        )

    prompt = build_prompt(prepared.curation, prepared.lint_issues)
    return await run_with_attempts(
        lambda: _run_audit_prompt(
            prepared,
            prompt,
            phase=f"audit {series_id}",
            timeout=timeout,
            on_progress=on_progress,
        ),
        attempts=_AUDIT_ATTEMPTS,
        label="audit",
        on_progress=on_progress,
    )


# -- Apply audit --

_FACT_IDENTITY_KEY: dict[str, str] = {
    "era_boundaries": "label",
    "known_gaps": "number",
    "sub_series": "label",
}


def _merge_facts(
    series_facts: dict,
    update: AuditFactUpdate,
    prov: dict,
) -> None:
    for key, items in [
        ("era_boundaries", update.era_boundaries),
        ("known_gaps", update.known_gaps),
        ("sub_series", update.sub_series),
    ]:
        id_field = _FACT_IDENTITY_KEY[key]
        existing = {e.get(id_field): e for e in series_facts.get(key, [])}
        for item in items:
            ident = getattr(item, id_field)
            existing[ident] = {**item.model_dump(), **prov}
        series_facts[key] = list(existing.values())


def apply_audit(
    series_id: str,
    result: AuditResult,
    *,
    model_name: str = _DEFAULT_MODEL,
    dry_run: bool = False,
    on_progress: Progress = _noop,
    usage: dict[str, int] | None = None,
) -> str:
    """Store audit result. Returns 'approved', 'escalated', or 'overridden'.

    ``usage`` (requests / input_tokens / output_tokens) is recorded in
    the review block next to who audited and when.
    """
    path = CURATION_DIR / f"{series_id}.json"
    data = json.loads(path.read_text())
    review = data.setdefault("review", {})
    now = datetime.now(tz=UTC).isoformat()

    # Verdict first: an escalated run must not touch album state.
    # Its overrides are recorded in the trail as a proposal for the
    # human reviewer; only an approving run materializes them.
    hard_flags = critical_issues(data.get("regression_flags") or [])
    gate_concerns = [f"[hard-gate] {f}" for f in hard_flags]
    escalated = bool(hard_flags) or not result.approve or len(result.concerns) > 5

    albums_by_id = {a["album_id"]: a for a in data.get("albums", [])}
    existing_overrides = {o["album_id"]: o for o in review.get("overrides", [])}
    for o in result.overrides:
        album = albums_by_id.get(o.album_id)
        if album is None:
            on_progress(
                f"  [warning] Override skipped: album_id {o.album_id!r} "
                f"not found in curation"
            )
            continue
        # Materialize into the album record: include flags are the one
        # source of truth for apply and later audit rounds. The
        # overrides list below is an audit trail only.
        if escalated:
            pass
        elif o.action == "exclude":
            album["include"] = False
            album["exclude_reason"] = o.reason
        else:
            album["include"] = True
            album["exclude_reason"] = ""
        existing_overrides[o.album_id] = {
            "album_id": o.album_id,
            "provider": o.provider,
            "action": o.action,
            "reason": o.reason,
            "audited_by": model_name,
            "audited_at": now,
        }
    if result.overrides:
        review["overrides"] = list(existing_overrides.values())

    series_facts = data.setdefault("series_facts", {})
    prov = fact_provenance(by=model_name, at=now, audited=True)
    for update in result.fact_updates:
        if update.mode == "replace":
            series_facts["era_boundaries"] = [
                {**e.model_dump(), **prov} for e in update.era_boundaries
            ]
            series_facts["known_gaps"] = [
                {**g.model_dump(), **prov} for g in update.known_gaps
            ]
            series_facts["sub_series"] = [
                {**s.model_dump(), **prov} for s in update.sub_series
            ]
        else:
            _merge_facts(series_facts, update, prov)

    # Hard gate: critical deterministic regressions (include-collapse,
    # facts-wipe vs the previous curation) force escalation no matter
    # what the audit model concluded. Approval is necessary, not
    # sufficient; a human resolves these via catalog-review.
    if escalated:
        for c in gate_concerns:
            on_progress(f"  {c}")
        review["status"] = "escalated"
        action = "escalated"
    elif result.overrides or result.fact_updates:
        review["status"] = "approved"
        action = "overridden"
    else:
        review["status"] = "approved"
        action = "approved"

    review["audited_by"] = model_name
    review["audited_at"] = now
    if usage is not None:
        review["usage"] = usage
    review["concerns"] = result.concerns + gate_concerns

    if not dry_run:
        canonicalize(data)
        safe_write_json(path, data)
    else:
        # A dry run has to show *what* it would change, not just how
        # much: an override on an already hand-edited album replaces
        # that album's trail entry, so the reviewer needs the targets.
        on_progress(f"Dry-run for {series_id}")
        on_progress(f"  Action: {action}")
        on_progress(f"  Concerns: {len(result.concerns)}")
        for c in result.concerns:
            on_progress(f"    - {c}")
        on_progress(f"  Overrides: {len(result.overrides)}")
        for o in result.overrides:
            on_progress(f"    - {o.action} {o.provider}:{o.album_id}: {o.reason}")
        on_progress(f"  Fact updates: {len(result.fact_updates)}")
        for update in result.fact_updates:
            on_progress(
                f"    - mode={update.mode} eras={len(update.era_boundaries)} "
                f"gaps={len(update.known_gaps)} sub_series={len(update.sub_series)}"
            )

    return action


@dataclass
class AuditAllResult:
    """Summary of auditing multiple series."""

    approved: int = 0
    escalated: int = 0
    overridden: int = 0
    failed: list[str] = field(default_factory=list)


async def audit_series(
    series_ids: list[str],
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 600,
    force: bool = False,
    dry_run: bool = False,
    providers: list | None = None,
    on_progress: Progress = _noop,
) -> AuditAllResult:
    """Audit one or more series. Returns summary counts."""
    summary = AuditAllResult()

    on_progress(f"Auditing {len(series_ids)} series with {model_name}")
    for sid in series_ids:
        on_progress(f"\n{sid}")
        try:
            usage = RunUsage()
            result = await audit_one(
                sid,
                model_name=model_name,
                timeout=timeout,
                force=force,
                providers=providers,
                on_progress=on_progress,
                usage=usage,
            )
            if result is None:
                continue
            on_progress(
                f"  Usage: {usage.requests} requests, "
                f"{usage.input_tokens} in / {usage.output_tokens} out tokens"
            )
            action = apply_audit(
                sid,
                result,
                model_name=model_name,
                dry_run=dry_run,
                on_progress=on_progress,
                usage=usage_summary(usage),
            )
            if action == "approved":
                summary.approved += 1
            elif action == "escalated":
                summary.escalated += 1
            else:
                summary.overridden += 1
        except Exception as e:
            err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
            on_progress(f"Failed: {err}")
            summary.failed.append(sid)

    on_progress(
        f"\nDone: {summary.approved} approved, "
        f"{summary.overridden} overridden, "
        f"{summary.escalated} escalated, "
        f"{len(summary.failed)} failed"
    )
    return summary
