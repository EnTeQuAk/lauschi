#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic-ai>=1.62.0",
#   "pydantic>=2.0",
#   "requests",
#   "diskcache",
#   "rich",
#   "ruamel.yaml",
# ]
# ///
"""
verify-series.py — 4-eye principle: second model verifies AI review decisions.

Reads a kimi-reviewed curation JSON and asks a second model (minimax-m2.5)
to verify the decisions. If both models agree, auto-approves and writes to
series.yaml. If the second model disagrees, marks for human review.

Pipeline status flow:
  curated → ai_reviewed → ai_verified → approved
                                      → escalated (disagreement)

Usage
-----
  mise exec -- uv run scripts/verify-series.py sternenschweif
  mise exec -- uv run scripts/verify-series.py --all
  mise exec -- uv run scripts/verify-series.py --dry-run --all
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import requests
from pydantic import BaseModel, Field
from pydantic_ai import Agent, RunContext
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import UsageLimits
from rich import box
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel
from rich.table import Table
from ruamel.yaml import YAML

console = Console()

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
SERIES_YAML  = REPO_ROOT / "assets" / "catalog" / "series.yaml"

sys.path.insert(0, str(Path(__file__).parent))
from spotify_cache import SpotifyClient  # noqa: E402

_OPENCODE_BASE_URL = "https://opencode.ai/zen/v1"
_VERIFY_MODEL      = "minimax-m2.5"
_MAX_RETRIES       = 3
_RETRY_DELAY       = 5


# ── Output model ───────────────────────────────────────────────────────────────

class OverrideVerdict(BaseModel):
    album_id: str
    agree: bool
    reason: str = ""


class SplitVerdict(BaseModel):
    new_id: str
    agree: bool
    reason: str = ""


class VerifyResult(BaseModel):
    series_id: str
    approve: bool = Field(
        description="True if the curation looks correct overall. "
        "False if there are issues that need human attention.",
    )
    override_verdicts: list[OverrideVerdict] = Field(default_factory=list)
    split_verdicts: list[SplitVerdict] = Field(default_factory=list)
    concerns: str = Field(
        default="",
        description="Any concerns or issues found. Empty if everything looks good.",
    )


# ── Deps ───────────────────────────────────────────────────────────────────────

@dataclass
class Deps:
    spotify: SpotifyClient
    series_id: str
    curation: dict
    _lookup_count: int = field(default=0, init=False)
    _MAX_LOOKUPS: int = 2


# ── System prompt ──────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = """\
You are the second reviewer in a 4-eye verification process for "lauschi",
a DACH children's audio player catalog.

A first AI (kimi-k2.5) has already curated this series (decided which Spotify
albums to include/exclude) and reviewed its own work (proposed overrides and
splits). Your job is to independently verify those decisions.

## What you're checking

1. **Included albums**: Do these look like real episodes of this series?
   Check that titles match the series, episode numbers are sensible, and
   nothing obviously wrong is included.

2. **Excluded albums**: Were these correctly excluded? Check that real
   episodes weren't accidentally excluded. Common valid exclusions:
   compilations, box sets, best-of, soundtracks, Lieder albums.

3. **Overrides** (changes the first AI proposed): Do you agree with each?
   Overrides flip an album from included→excluded or excluded→included.

4. **Splits** (proposed new sub-series): Do these make sense? A split
   separates albums that belong to a different product (different era,
   different voice cast, different branding) into their own series entry.

## Your decision

- Set `approve: true` if the curation is sound overall. Minor issues that
  don't affect the user experience are OK.
- Set `approve: false` if you find significant problems: real episodes
  excluded, wrong content included, bad splits, or missing metadata.
- Fill `concerns` with any issues you found, even if you still approve.
- For each override and split, state whether you agree.

## Rules

- You have tools to spot-check: `album_details` to verify specific albums,
  `wikipedia_lookup` for factual context. Use them sparingly — you're
  verifying, not redoing the full review.
- Max 2 lookups total (wikipedia + web combined).
- Max 5 album detail checks.
- When in doubt, flag concerns but still approve — false rejections are
  worse than letting a minor issue through. A human will see your concerns.
- Do NOT propose new overrides or splits. Only verify existing ones.
"""


# ── Agent builder ──────────────────────────────────────────────────────────────

def build_verify_agent(model_name: str, api_key: str) -> Agent[Deps, VerifyResult]:
    provider = OpenAIProvider(base_url=_OPENCODE_BASE_URL, api_key=api_key)
    model = OpenAIChatModel(model_name, provider=provider)
    agent: Agent[Deps, VerifyResult] = Agent(
        model,
        output_type=VerifyResult,
        system_prompt=_SYSTEM_PROMPT,
        retries=2,
    )

    @agent.tool
    def album_details(
        ctx: RunContext[Deps], album_ids: list[str],
    ) -> list[dict] | str:
        """Get detailed info about Spotify albums: release date, track count,
        track names. Use to spot-check whether include/exclude decisions are
        correct. Takes a list of IDs (batch lookup)."""
        results = []
        for album_id in album_ids[:5]:
            info = ctx.deps.spotify.album_details(album_id)
            if "error" in info:
                results.append({"id": album_id, "error": "not found"})
            else:
                results.append(info)
                console.print(
                    f"  [dim]📀 album_details({album_id[:8]}…) → "
                    f"{info['name']} ({info['release_date']}, "
                    f"{info['total_tracks']} tracks)[/]",
                )
        return results

    @agent.tool
    def wikipedia_lookup(ctx: RunContext[Deps], query: str) -> str:
        """Look up on German Wikipedia for factual context about a series."""
        if ctx.deps._lookup_count >= ctx.deps._MAX_LOOKUPS:
            return "Lookup limit reached."
        ctx.deps._lookup_count += 1
        try:
            headers = {
                "User-Agent": "lauschi-catalog-verify/1.0 "
                "(https://github.com/EnTeQuAk/lauschi)",
            }
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={
                    "action": "query", "list": "search",
                    "srsearch": query, "srlimit": 3, "format": "json",
                },
                timeout=10,
            )
            r.raise_for_status()
            hits = r.json().get("query", {}).get("search", [])
            if not hits:
                console.print(
                    f"  [dim]📖 wikipedia_lookup({query!r}) → no article[/]",
                )
                return "No Wikipedia article found."
            title = hits[0]["title"]
            r = requests.get(
                "https://de.wikipedia.org/w/api.php",
                headers=headers,
                params={
                    "action": "query", "titles": title,
                    "prop": "extracts", "exintro": False,
                    "explaintext": True, "exchars": 3000,
                    "format": "json",
                },
                timeout=10,
            )
            r.raise_for_status()
            pages = r.json().get("query", {}).get("pages", {})
            extract = next(iter(pages.values())).get("extract", "")
            console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → {title}[/]")
            return f"Wikipedia: {title}\n\n{extract}"
        except Exception as e:
            console.print(f"  [dim]📖 wikipedia_lookup({query!r}) → error: {e}[/]")
            return f"Wikipedia lookup failed: {e}"

    return agent


# ── Helpers ────────────────────────────────────────────────────────────────────

def effective_albums(data: dict) -> list[dict]:
    """Apply review overrides to get the effective album list."""
    albums = list(data.get("series", {}).get("albums", []))
    overrides = {
        o["album_id"]: o
        for o in data.get("review", {}).get("overrides", [])
    }
    for album in albums:
        aid = album["spotify_album_id"]
        if aid in overrides:
            ov = overrides[aid]
            if ov["action"] == "exclude":
                album = {**album, "include": False}
            elif ov["action"] == "include":
                album = {**album, "include": True}
    return albums


def _build_verify_prompt(curation: dict) -> str:
    """Build the prompt showing the series state + kimi's review decisions."""
    series = curation["series"]
    review = curation.get("review", {})
    albums = series.get("albums", [])

    included = sorted(
        [a for a in albums if a.get("include")],
        key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
    )
    excluded = sorted(
        [a for a in albums if not a.get("include")],
        key=lambda a: a["title"],
    )

    lines = [
        f"## Series: {series['title']} (id: {series['id']})",
        f"Keywords: {series.get('keywords', [])}",
        f"Artist IDs: {series.get('spotify_artist_ids', [])}",
        f"Episode pattern: {series.get('episode_pattern', 'none')}",
        f"Age note: {series.get('age_note', 'none')}",
        "",
        f"### Included albums ({len(included)})",
    ]

    for a in included:
        ep = a.get("episode_num")
        ep_str = f"Ep {ep}: " if ep is not None else ""
        lines.append(f"  ✅ {ep_str}{a['title']} [{a['spotify_album_id'][:8]}…]")

    lines.append(f"\n### Excluded albums ({len(excluded)})")
    for a in excluded:
        reason = a.get("exclude_reason", "")
        lines.append(
            f"  ❌ {a['title']} [{a['spotify_album_id'][:8]}…]"
            f"{f' — {reason}' if reason else ''}",
        )

    # Kimi's review decisions
    overrides = review.get("overrides", [])
    splits = review.get("splits", [])
    notes = review.get("notes", "")

    if overrides:
        lines.append(f"\n### Kimi review overrides ({len(overrides)})")
        for o in overrides:
            lines.append(
                f"  🔄 {o['action']}: {o['album_id'][:8]}… — {o.get('reason', '')}",
            )

    if splits:
        lines.append(f"\n### Kimi split proposals ({len(splits)})")
        for s in splits:
            lines.append(
                f"  ✂️  {s['new_title']} ({s['new_id']}): "
                f"{len(s['album_ids'])} albums — {s.get('reason', '')}",
            )

    if notes:
        lines.append(f"\n### Kimi reviewer notes\n{notes[:1000]}")

    lines.append("")
    lines.append(
        "Review the above. Use tools to spot-check if anything looks off. "
        "Then give your verdict.",
    )

    return "\n".join(lines)


# ── Write to series.yaml ──────────────────────────────────────────────────────

def write_to_yaml(data: dict) -> None:
    """Write an approved series to series.yaml."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False
    yaml.width = 100

    series = data["series"]
    review = data.get("review", {})
    albums = series.get("albums", [])

    # Apply overrides
    overrides = {o["album_id"]: o for o in review.get("overrides", [])}
    effective = []
    for a in albums:
        aid = a["spotify_album_id"]
        if aid in overrides:
            ov = overrides[aid]
            if ov["action"] == "exclude":
                continue  # Skip excluded
            # Include override — keep it
        elif not a.get("include"):
            continue  # Originally excluded, no override
        effective.append(a)

    inc = sorted(
        effective,
        key=lambda a: (a.get("episode_num") or 999_999, a["title"]),
    )

    entry: dict[str, Any] = {"id": series["id"], "title": series["title"]}
    if series.get("aliases"):
        entry["aliases"] = series["aliases"]
    if series.get("keywords"):
        entry["keywords"] = series["keywords"]
    if series.get("spotify_artist_ids"):
        entry["spotify_artist_ids"] = series["spotify_artist_ids"]
    if series.get("episode_pattern"):
        entry["episode_pattern"] = series["episode_pattern"]
    if inc:
        entry["albums"] = [
            (
                {
                    "id": e["spotify_album_id"],
                    "episode": e["episode_num"],
                    "title": e["title"],
                }
                if e.get("episode_num") is not None
                else {"id": e["spotify_album_id"], "title": e["title"]}
            )
            for e in inc
        ]

    with SERIES_YAML.open(encoding="utf-8") as f:
        doc = yaml.load(f) or {}
    sl: list = doc.get("series", [])
    idx = next((i for i, s in enumerate(sl) if s.get("id") == series["id"]), None)
    if idx is not None:
        sl[idx] = entry
    else:
        sl.append(entry)
    with SERIES_YAML.open("w", encoding="utf-8") as f:
        yaml.dump(doc, f)


# ── Core verify logic ─────────────────────────────────────────────────────────

async def verify_one(
    model_name: str,
    api_key: str,
    series_id: str,
    spotify: SpotifyClient,
    timeout: int,
    *,
    force: bool = False,
) -> VerifyResult | None:
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        console.print(f"[red]Not found: {path}[/]")
        return None

    curation = json.loads(path.read_text())

    if "series" not in curation:
        console.print(f"[dim]Skipping {series_id} (no series data)[/]")
        return None

    # Only verify series that have been AI-reviewed
    review = curation.get("review", {})
    if not review.get("reviewed_at"):
        console.print(f"[dim]Skipping {series_id} (not yet AI-reviewed)[/]")
        return None

    if not force:
        # Skip already verified/approved
        status = review.get("status")
        if status in ("approved", "ai_verified"):
            console.print(f"[dim]Skipping {series_id} (already {status})[/]")
            return None

    # Skip rejected (even with --force, rejected = human decision)
    if review.get("status") == "rejected":
        console.print(f"[dim]Skipping {series_id} (rejected)[/]")
        return None

    deps = Deps(spotify=spotify, series_id=series_id, curation=curation)
    agent = build_verify_agent(model_name, api_key)
    prompt = _build_verify_prompt(curation)

    async def _run() -> VerifyResult:
        async with agent.iter(
            prompt, deps=deps,
            usage_limits=UsageLimits(request_limit=30),
        ) as run:
            async for node in run:
                if not hasattr(node, "model_response"):
                    continue
                for part in node.model_response.parts:
                    text = getattr(part, "content", None)
                    if not isinstance(text, str) or len(text.strip()) <= 80:
                        continue
                    kind = getattr(part, "part_kind", "")
                    label = "💭 reasoning" if kind == "thinking" else "💭"
                    console.print(
                        Panel(
                            Markdown(text.strip()),
                            border_style="dim",
                            title=label,
                            padding=(0, 1),
                        ),
                    )
            return run.result.output

    last_err: Exception | None = None
    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            return await asyncio.wait_for(_run(), timeout=timeout)
        except asyncio.TimeoutError:
            raise TimeoutError(f"Timed out after {timeout}s") from None
        except Exception as e:
            last_err = e
            err_str = str(e)
            if (
                "<!DOCTYPE" in err_str or "500" in err_str
            ) and attempt < _MAX_RETRIES:
                console.print(
                    f"[yellow]Attempt {attempt}/{_MAX_RETRIES} failed "
                    f"(proxy error), retrying in {_RETRY_DELAY}s…[/]",
                )
                await asyncio.sleep(_RETRY_DELAY)
                continue
            raise
    raise RuntimeError(f"Exhausted {_MAX_RETRIES} retries: {last_err}")


def apply_verification(
    series_id: str, result: VerifyResult, *, dry_run: bool = False,
) -> str:
    """Write verification result. Returns action taken."""
    path = CURATION_DIR / f"{series_id}.json"
    data = json.loads(path.read_text())
    review = data.setdefault("review", {})

    # Store verification
    review["verification"] = {
        "model": _VERIFY_MODEL,
        "verified_at": datetime.now(tz=UTC).isoformat(),
        "approve": result.approve,
        "concerns": result.concerns,
        "override_verdicts": [v.model_dump() for v in result.override_verdicts],
        "split_verdicts": [v.model_dump() for v in result.split_verdicts],
    }

    # Check for disagreements on overrides/splits
    override_disagreements = [
        v for v in result.override_verdicts if not v.agree
    ]
    split_disagreements = [v for v in result.split_verdicts if not v.agree]
    has_disagreements = bool(override_disagreements or split_disagreements)

    if result.approve and not has_disagreements:
        action = "approved"
        review["status"] = "approved"
        if not dry_run:
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False))
            write_to_yaml(data)
    else:
        action = "escalated"
        review["status"] = "escalated"
        if not dry_run:
            path.write_text(json.dumps(data, indent=2, ensure_ascii=False))

    return action


# ── CLI ────────────────────────────────────────────────────────────────────────

def _print_result(series_id: str, result: VerifyResult, action: str) -> None:
    color = "green" if action == "approved" else "yellow"
    icon = "✅" if action == "approved" else "⚠️"

    console.print(f"\n{icon} [{color}]{series_id}[/] → {action}")

    if result.concerns:
        console.print(f"  Concerns: {result.concerns[:200]}")

    agreed_ov = [v for v in result.override_verdicts if v.agree]
    disagreed_ov = [v for v in result.override_verdicts if not v.agree]
    if agreed_ov:
        console.print(f"  Overrides agreed: {len(agreed_ov)}")
    for v in disagreed_ov[:5]:
        console.print(f"  👎 Override {v.album_id[:8]}…: {v.reason}")
    if len(disagreed_ov) > 5:
        console.print(f"  … and {len(disagreed_ov) - 5} more disagreements")

    agreed_sp = [v for v in result.split_verdicts if v.agree]
    disagreed_sp = [v for v in result.split_verdicts if not v.agree]
    if agreed_sp:
        console.print(f"  Splits agreed: {len(agreed_sp)}")
    for v in disagreed_sp:
        console.print(f"  👎 Split {v.new_id}: {v.reason}")


async def main() -> None:
    parser = argparse.ArgumentParser(description="Verify AI-reviewed series")
    parser.add_argument(
        "series_id", nargs="?",
        help="Series ID to verify (omit for --all)",
    )
    parser.add_argument("--all", action="store_true", help="Verify all pending")
    parser.add_argument("--force", action="store_true", help="Re-verify already approved")
    parser.add_argument("--dry-run", action="store_true", help="Don't write files")
    parser.add_argument(
        "--model", default=_VERIFY_MODEL,
        help=f"Model to use (default: {_VERIFY_MODEL})",
    )
    parser.add_argument("--timeout", type=int, default=120, help="Timeout per series")
    args = parser.parse_args()

    api_key = os.environ.get("OPENCODE_API_KEY", "")
    if not api_key:
        console.print("[red]OPENCODE_API_KEY not set[/]")
        sys.exit(1)

    spotify = SpotifyClient()

    if args.series_id:
        ids = [args.series_id]
    elif args.all:
        ids = sorted(
            p.stem
            for p in CURATION_DIR.glob("*.json")
        )
    else:
        parser.print_help()
        sys.exit(1)

    approved = 0
    escalated = 0
    skipped = 0

    for sid in ids:
        console.rule(f"[bold]{sid}")
        try:
            result = await verify_one(
                args.model, api_key, sid, spotify, args.timeout,
                force=args.force,
            )
            if result is None:
                skipped += 1
                continue

            action = apply_verification(sid, result, dry_run=args.dry_run)
            _print_result(sid, result, action)

            if action == "approved":
                approved += 1
            else:
                escalated += 1
        except Exception as e:
            console.print(f"[red]Error verifying {sid}: {e}[/]")
            escalated += 1

    # Summary
    console.print()
    table = Table(title="Verification Summary", box=box.SIMPLE)
    table.add_column("Status", style="bold")
    table.add_column("Count", justify="right")
    table.add_row("Approved", f"[green]{approved}[/]")
    table.add_row("Escalated", f"[yellow]{escalated}[/]")
    table.add_row("Skipped", f"[dim]{skipped}[/]")
    table.add_row("Total", str(approved + escalated + skipped))
    console.print(table)

    if args.dry_run:
        console.print("[yellow]Dry run — no files written.[/]")


if __name__ == "__main__":
    asyncio.run(main())
