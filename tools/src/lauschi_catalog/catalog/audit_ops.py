"""Library functions for the 4-eye audit pipeline.

Reads a curated series and asks a different model to independently
review. Returns structured results via callbacks for progress.

Pipeline: curated -> audited -> approved / escalated
"""

from __future__ import annotations

import asyncio
import json
import os
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field
from pydantic_ai import Agent, ModelRetry, RunContext, ToolOutput

from lauschi_catalog._opencode import (
    build_mistral_model,
    build_opencode_model,
    get_model_settings,
)
from lauschi_catalog.catalog.canonical import canonicalize
from lauschi_catalog.catalog.facts import (
    EraBoundaryProposal,
    KnownGapProposal,
    SubSeriesProposal,
)
from lauschi_catalog.catalog.lifecycle import review_is_stale
from lauschi_catalog.catalog.loader import load_raw, save_raw
from lauschi_catalog.catalog.paths import CURATION_DIR
from lauschi_catalog.commands.lint import lint_curation
from lauschi_catalog.retry import is_retryable
from lauschi_catalog.run import run_agent_streaming
from lauschi_catalog.search import brave_search
from lauschi_catalog.search import fetch_page as _fetch_page

_DEFAULT_MODEL = "minimax-m2.7"
_MAX_RETRIES = 3
_RETRY_DELAY = 5

Provider = Literal["spotify", "apple_music"]

Progress = Callable[[str], None]
_noop: Progress = lambda _msg: None


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
class Deps:
    series_id: str
    curation: dict
    lint_issues: list[str]
    on_progress: Progress = _noop
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _MAX_SEARCHES: int = 3
    _MAX_FETCHES: int = 2


_SYSTEM_PROMPT = """\
You are the auditor in a 4-eye review process for "lauschi", a DACH
children's audio player catalog.

A first AI has curated this series (decided include/exclude for each
album) and proposed structural facts (era_boundaries, known_gaps,
sub_series). Your job is to independently verify that work.

## What you are checking

1. **Included albums**: Do they look like real episodes? Cross-provider
   pairs (same episode on Spotify + Apple Music) are EXPECTED; they are
   the same content in different catalogs. Both should stay included.
2. **Excluded albums**: Were they correctly excluded? Real episodes
   should not be excluded. Valid exclusions: compilations, box sets,
   soundtracks, Lieder, karaoke, unrelated content.
3. **Structural facts**: Do era_boundaries match release-date clusters?
   Do known_gaps have plausible reasons (legal dispute, skipped number)?
   Do sub_series labels match the claimed albums?
4. **Lint findings**: The deterministic linter flagged structural
   issues before you saw the curation. These are computed from the
   data, not opinions. Every lint finding must be addressed: either
   fix it (via override or fact_update), record it as a concern, or
   explain why it's a false positive. Do not ignore lint findings.

## Your decision

- `approve: true` if sound overall. Minor overrides and a few concerns
  are fine.
- `approve: false` if significant problems: real episodes excluded,
  wrong content included, facts that contradict album data.
- Use the `overrides` field for per-album fixes (exclude a compilation
  that curate missed, include a real episode that was wrongly dropped).
- Use the `concerns` field for anything worth human attention even if
  you still approve. Concerns are surfaced in pipeline output.
- Use the `fact_updates` field to fix, add, or remove structural facts.
  Prefer "merge" mode (adds/changes on top of existing facts).

## Confidence budget

HIGH-confidence decisions from curate are unlikely to be wrong;
sample them lightly. MEDIUM and LOW confidence decisions warrant
per-item review. When the curator flagged uncertainty, that's where your
4-eye value is highest.

## Tools

- **web_search**: Search for series info. Max 3 searches.
- **fetch_page**: Fetch a URL for details. Max 2 fetches.

All other output (overrides, concerns, fact_updates) goes directly
into the structured `submit_audit` output. No separate tools needed.

## Rules

- Do NOT propose splits or new series entries.
- Do NOT update the episode_pattern. If the pattern looks wrong, flag
  it as a concern and let the human decide.
- When in doubt, escalate. lauschi is a kids' catalog; the cost of
  bad content reaching a child is higher than a human review.
"""


def _build_audit_agent(model_name: str, api_key: str, on_progress: Progress = _noop):
    model = (
        build_mistral_model(model_name, api_key)
        if model_name.startswith("mistral-")
        else build_opencode_model(model_name, api_key)
    )
    agent: Agent[Deps, AuditResult] = Agent(
        model,
        output_type=ToolOutput(
            AuditResult,
            name="submit_audit",
            description=(
                "Submit your audit verdict. Use overrides and fact_updates "
                "for targeted fixes; concerns for anything worth flagging."
            ),
        ),
        instructions=_SYSTEM_PROMPT,
        model_settings=get_model_settings("audit", model_name),
        tool_retries=2,
        output_retries=2,
    )

    @agent.tool
    def web_search(ctx: RunContext[Deps], query: str) -> list[dict]:
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            raise ModelRetry(
                f"Search limit reached ({ctx.deps._MAX_SEARCHES}/{ctx.deps._MAX_SEARCHES}). "
                f"Make your audit decision using the information you already have."
            )
        ctx.deps._search_count += 1
        results = brave_search(query, count=5)
        n = len([r for r in results if "error" not in r])
        ctx.deps.on_progress(f"  web_search({query!r}) -> {n} results")
        return results

    @agent.tool
    def fetch_page(ctx: RunContext[Deps], url: str) -> str:
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            raise ModelRetry(
                f"Fetch limit reached ({ctx.deps._MAX_FETCHES}/{ctx.deps._MAX_FETCHES}). "
                f"Make your audit decision using the information you already have."
            )
        ctx.deps._fetch_count += 1
        content = _fetch_page(url, max_chars=4000)
        ctx.deps.on_progress(f"  fetch_page({url[:60]}) -> {len(content)} chars")
        return content

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
        "",
        f"### Included albums ({len(included)})",
    ]
    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        conf = a.get("confidence", "high")
        conf_tag = f" [{conf}]" if conf != "high" else ""
        notes = a.get("notes", "")
        notes_str = f" -- notes: {notes}" if notes and conf != "high" else ""
        lines.append(
            f"  [{a.get('provider', '?')}] {ep_str}{a['title']}{conf_tag}{notes_str}"
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
            f"  [{a.get('provider', '?')}] {a['title']}{rel_str}{reason_str}{notes_str}"
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
            lines.append(
                f"  Known gap: episode {g.get('number', '?')} -- {g.get('reason', '')}{status}"
            )
        for s in facts.get("sub_series", []):
            aud = s.get("audited_by")
            status = f" [audited by {aud}]" if aud else " [unaudited]"
            lines.append(
                f"  Sub-series: {s.get('label', '?')} -- {s.get('reason', '')}{status}"
            )

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
        if review_is_stale(curation):
            on_progress(
                f"Skipping {series_id}: audit is stale "
                f"(curate ran after last audit). Re-run curate first."
            )
            return None
        if status in ("approved", "audited"):
            on_progress(f"Skipping {series_id} (already {status})")
            return None
        if status == "rejected":
            on_progress(f"Skipping {series_id} (rejected)")
            return None

    lint_issues = lint_curation(curation)
    if lint_issues:
        on_progress(f"  Lint: {len(lint_issues)} issues")

    agent = _build_audit_agent(model_name, api_key, on_progress)
    prompt = build_prompt(curation, lint_issues)

    for attempt in range(_MAX_RETRIES):
        deps = Deps(
            series_id=series_id,
            curation=curation,
            lint_issues=lint_issues,
            on_progress=on_progress,
        )
        try:
            result = await asyncio.wait_for(
                run_agent_streaming(agent, prompt, deps, request_limit=20),
                timeout=timeout,
            )
            return result
        except asyncio.TimeoutError:
            raise
        except Exception as e:
            if is_retryable(e) and attempt < _MAX_RETRIES - 1:
                err = f"{type(e).__name__}: {e}" if str(e) else type(e).__name__
                on_progress(f"Attempt {attempt + 1} failed: {err}")
                await asyncio.sleep(_RETRY_DELAY)
            else:
                raise
    return None


# -- Apply audit --

_FACT_IDENTITY_KEY: dict[str, str] = {
    "era_boundaries": "label",
    "known_gaps": "number",
    "sub_series": "label",
}


def _merge_facts(
    series_facts: dict,
    update: AuditFactUpdate,
    model_name: str,
    now: str,
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
            existing[ident] = {**item.model_dump(), "audited_by": model_name, "audited_at": now}
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

    existing_overrides = {o["album_id"]: o for o in review.get("overrides", [])}
    for o in result.overrides:
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
    for update in result.fact_updates:
        if update.mode == "replace":
            series_facts["era_boundaries"] = [
                {**e.model_dump(), "audited_by": model_name, "audited_at": now}
                for e in update.era_boundaries
            ]
            series_facts["known_gaps"] = [
                {**g.model_dump(), "audited_by": model_name, "audited_at": now}
                for g in update.known_gaps
            ]
            series_facts["sub_series"] = [
                {**s.model_dump(), "audited_by": model_name, "audited_at": now}
                for s in update.sub_series
            ]
        else:
            _merge_facts(series_facts, update, model_name, now)

    if not result.approve or len(result.concerns) > 5:
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
    review["concerns"] = result.concerns

    if not dry_run:
        canonicalize(data)
        save_raw(data, path)
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
    on_progress: Progress = _noop,
) -> AuditAllResult:
    """Audit one or more series. Returns summary counts."""
    summary = AuditAllResult()

    on_progress(f"Auditing {len(series_ids)} series with {model_name}")
    for sid in series_ids:
        on_progress(f"\n{sid}")
        try:
            result = await audit_one(
                sid, model_name=model_name, timeout=timeout,
                force=force, on_progress=on_progress,
            )
            if result is None:
                continue
            action = apply_audit(
                sid, result, model_name=model_name,
                dry_run=dry_run, on_progress=on_progress,
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
