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
from pydantic_ai import Agent, RunContext, ToolOutput

from lauschi_catalog._opencode import (
    build_model,
    get_model_settings,
)
from lauschi_catalog.agent_deps import AgentDeps, Progress, _noop
from lauschi_catalog.agent_tools import build_agent_tools
from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.catalog.facts import (
    EraBoundaryProposal,
    KnownGapProposal,
    SubSeriesProposal,
    fact_provenance,
)
from lauschi_catalog.catalog.analysis import analyze_series
from lauschi_catalog.catalog.io import safe_write_json
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.catalog.lint_ops import critical_issues, lint_curation
from lauschi_catalog.prompts import load_curate_skill
from lauschi_catalog.agent_hooks import build_progress_hooks
from lauschi_catalog.rate_limit import run_with_rate_limit_retry
from lauschi_catalog.run import run_agent

_DEFAULT_MODEL = "minimax-m2.7"
_MAX_RETRIES = 12
_RETRY_DELAY = 10

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


def build_prompt(curation: dict, lint_issues: list[str]) -> str:
    albums = curation.get("albums", [])
    included = sorted(
        [a for a in albums if a.get("include")],
        key=lambda a: (
            a.get("episode_num") is None,
            a.get("episode_num"),
            a.get("release_date") or "",
            a["title"],
        ),
    )
    excluded = [a for a in albums if not a.get("include")]

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
    lines += [
        "",
        f"### Included albums ({len(included)})",
    ]
    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        conf = a.get("confidence", "high")
        conf_tag = f" [{conf}]" if conf != "high" else ""
        notes = a.get("notes", "")
        notes_str = f" -- notes: {notes}" if notes and conf != "high" else ""
        lines.append(
            f"  [{a.get('provider', '?')}:{a['album_id']}] {ep_str}{a['title']}{rel_str}{conf_tag}{notes_str}"
        )

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded:
        reason = a.get("exclude_reason", "")
        rel = a.get("release_date") or ""
        rel_str = f" ({rel})" if rel else ""
        reason_str = f" -- {reason}" if reason else ""
        notes = a.get("notes", "")
        notes_str = f" (notes: {notes})" if notes else ""
        lines.append(
            f"  [{a.get('provider', '?')}:{a['album_id']}] {a['title']}{rel_str}{reason_str}{notes_str}"
        )

    facts = curation.get("series_facts")
    if facts:
        lines.append("\n### Series facts")
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

    analysis = analyze_series(curation)
    analysis_parts: list[str] = []
    if analysis.get("gaps"):
        analysis_parts.append(
            f"  Gaps: {len(analysis['gaps'])} missing episodes ({analysis['gaps']})"
        )
    dupes = analysis.get("duplicates_within_provider") or []
    if dupes:
        by_prov: dict[str, list[int]] = {}
        for d in dupes:
            by_prov.setdefault(d["provider"], []).append(d["episode_num"])
        for prov, eps in by_prov.items():
            analysis_parts.append(f"  Duplicates on {prov}: episodes {sorted(eps)}")
    xpc = analysis.get("cross_provider_coverage") or {}
    missing_per = xpc.get("missing_per_provider") or {}
    for prov, missing_eps in missing_per.items():
        if missing_eps:
            analysis_parts.append(f"  {prov} missing: {missing_eps}")
    clusters = analysis.get("title_clusters") or []
    if clusters:
        analysis_parts.append(f"  Title clusters ({len(clusters)} groups):")
        for c in clusters:
            examples = ", ".join(c["examples"][:3])
            analysis_parts.append(
                f"    {c['shape']!r} ({c['count']} albums): {examples}"
            )
    pc = analysis.get("pattern_coverage")
    if isinstance(pc, dict):
        analysis_parts.append(f"  Pattern coverage: {pc['percentage']}%")
    if analysis_parts:
        lines.append("\n### Structural analysis (deterministic)")
        lines.extend(analysis_parts)

    if lint_issues:
        lines.append(f"\n### Lint findings ({len(lint_issues)})")
        lines.append(
            "Each finding below is a data-driven structural warning. "
            "For each one: fix it (override/fact_update), record as a "
            "concern, or explain why it's a false positive."
        )
        for issue in lint_issues:
            lines.append(f"  {issue}")

    lines.append(
        "\nAudit the above. Flag genuine errors, propose targeted fixes, "
        "and approve when sound."
    )
    return "\n".join(lines)


# -- Core audit --


async def audit_one(
    series_id: str,
    *,
    model_name: str = _DEFAULT_MODEL,
    timeout: int = 600,
    force: bool = False,
    providers: list | None = None,
    on_progress: Progress = _noop,
) -> AuditResult | None:
    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        on_progress("OPENCODE_API_KEY not set")
        return None

    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        on_progress(f"Not found: {path}")
        return None

    curation = json.loads(path.read_text())

    review = curation.get("review", {})
    status = review.get("status")
    if not force:
        if status in ("approved", "audited"):
            on_progress(f"Skipping {series_id} (already {status})")
            return None
        if status == "rejected":
            on_progress(f"Skipping {series_id} (rejected)")
            return None

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
    prompt = build_prompt(curation, lint_issues)

    deps = AuditDeps(
        series_id=series_id,
        curation=curation,
        lint_issues=lint_issues,
        providers=providers or [],
        on_progress=on_progress,
    )
    return await run_with_rate_limit_retry(
        lambda: asyncio.wait_for(
            run_agent(agent, prompt, deps, request_limit=20),
            timeout=timeout,
        ),
        phase=f"audit {series_id}",
        max_retries=_MAX_RETRIES,
        base_delay=float(_RETRY_DELAY),
        max_delay=300.0,
        retry_timeout=False,
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
) -> str:
    """Store audit result. Returns 'approved', 'escalated', or 'overridden'."""
    path = CURATION_DIR / f"{series_id}.json"
    data = json.loads(path.read_text())
    review = data.setdefault("review", {})
    now = datetime.now(tz=UTC).isoformat()

    known_ids = {a["album_id"] for a in data.get("albums", [])}
    existing_overrides = {o["album_id"]: o for o in review.get("overrides", [])}
    for o in result.overrides:
        if o.album_id not in known_ids:
            on_progress(
                f"  [warning] Override skipped: album_id {o.album_id!r} "
                f"not found in curation"
            )
            continue
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
    hard_flags = critical_issues(data.get("regression_flags") or [])
    gate_concerns = [f"[hard-gate] {f}" for f in hard_flags]
    if hard_flags:
        for c in gate_concerns:
            on_progress(f"  {c}")
        review["status"] = "escalated"
        action = "escalated"
    elif not result.approve or len(result.concerns) > 5:
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
    review["concerns"] = result.concerns + gate_concerns

    if not dry_run:
        canonicalize(data)
        safe_write_json(path, data)
    else:
        on_progress(f"Dry-run for {series_id}")
        on_progress(f"  Action: {action}")
        on_progress(f"  Concerns: {len(result.concerns)}")
        on_progress(f"  Overrides: {len(result.overrides)}")
        on_progress(f"  Fact updates: {len(result.fact_updates)}")

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
            result = await audit_one(
                sid,
                model_name=model_name,
                timeout=timeout,
                force=force,
                providers=providers,
                on_progress=on_progress,
            )
            if result is None:
                continue
            action = apply_audit(
                sid,
                result,
                model_name=model_name,
                dry_run=dry_run,
                on_progress=on_progress,
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
        f"{summary.escalated} escalated"
    )
    return summary
