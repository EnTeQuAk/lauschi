# Third-pass review sheet generator. One-off tooling for the manual
# catalog review; renders a compact per-series sheet so a reviewer can
# eyeball every decision without opening the JSON.
#
# Usage: uv run python review_sheet.py <series_id> [series_id ...]
#        uv run python review_sheet.py --list   (ids in review order)

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

CURATION_DIR = Path(__file__).resolve().parent.parent / "assets" / "catalog" / "curation"


def episode_coverage(albums: list[dict]) -> str:
    by_provider: dict[str, list[int]] = {}
    for a in albums:
        if a.get("include") and a.get("episode_num") is not None:
            by_provider.setdefault(a["provider"], []).append(a["episode_num"])
    if not by_provider:
        return "  (no episode numbers)"
    lines = []
    for prov, nums in sorted(by_provider.items()):
        nums = sorted(set(nums))
        full = set(range(nums[0], nums[-1] + 1))
        missing = sorted(full - set(nums))
        dupes = [n for n, c in Counter(
            a["episode_num"] for a in albums
            if a.get("include") and a.get("provider") == prov
            and a.get("episode_num") is not None
        ).items() if c > 1]
        line = f"  {prov}: {nums[0]}-{nums[-1]} ({len(nums)} eps)"
        if missing:
            line += f" MISSING {missing}"
        if dupes:
            line += f" DUPED {sorted(dupes)}"
        lines.append(line)
    return "\n".join(lines)


def render(sid: str) -> str:
    path = CURATION_DIR / f"{sid}.json"
    cur = json.loads(path.read_text())
    albums = cur.get("albums", [])
    inc = [a for a in albums if a.get("include")]
    exc = [a for a in albums if not a.get("include")]
    rev = cur.get("review") or {}

    out = []
    out.append("=" * 78)
    out.append(f"{sid}  |  {cur.get('title', '?')}")
    out.append(
        f"type={cur.get('content_type', 'hoerspiel')}  "
        f"pattern={cur.get('episode_pattern')!r}  "
        f"age={cur.get('age_note') or '-'}  "
        f"review={rev.get('status', '-')}"
    )
    notes = (cur.get("curator_notes") or "").strip()
    if notes:
        out.append(f"notes: {notes[:300]}")
    gaps = cur.get("series_facts", {}).get("known_gaps") or []
    if gaps:
        nums = [g.get("number") for g in gaps]
        out.append(f"known_gaps: {nums}")
    out.append(f"\nCOVERAGE ({len(inc)} included / {len(exc)} excluded)")
    out.append(episode_coverage(albums))

    out.append("\nINCLUDED:")
    for a in sorted(inc, key=lambda x: (x.get("episode_num") or 0, x.get("title", ""))):
        ep = a.get("episode_num")
        ep_s = f"{ep:>4}" if ep is not None else "   -"
        prov = "sp" if a["provider"] == "spotify" else "am"
        out.append(f"  {ep_s} [{prov}] {a.get('title', '?')[:90]}")

    out.append("\nEXCLUDED (grouped):")
    by_reason: dict[str, list[str]] = {}
    for a in exc:
        reason = (a.get("exclude_reason") or "?")[:40]
        by_reason.setdefault(reason, []).append(a.get("title", "?"))
    for reason, titles in sorted(by_reason.items(), key=lambda kv: -len(kv[1])):
        out.append(f"  [{reason}] x{len(titles)}")
        for t in titles[:6]:
            out.append(f"      - {t[:84]}")
        if len(titles) > 6:
            out.append(f"      ... {len(titles) - 6} more")

    concerns = rev.get("concerns") or []
    if concerns:
        out.append("\nAUDIT CONCERNS:")
        for c in concerns:
            out.append(f"  - {c[:250]}")
    return "\n".join(out)


def main() -> None:
    args = sys.argv[1:]
    if args == ["--list"]:
        ids = sorted(p.stem for p in CURATION_DIR.glob("*.json"))
        print("\n".join(ids))
        return
    for sid in args:
        print(render(sid))
        print()


if __name__ == "__main__":
    main()
