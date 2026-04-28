"""Backfill missing ``content_type`` on curation JSONs.

Curations created before the ``content_type`` field existed don't carry
it, but the review prompt's music branch only fires on explicit
``content_type == "music"``. Setting the default explicitly makes the
field always present and forecloses ambiguity.

We intentionally do NOT auto-classify music vs Hörspiel here. The
heuristic ``episode_pattern is null + most albums lack episode_num``
catches genuine music artists like detlev_jocker but also misclassifies
story-based Hörspiele like bobo_siebenschlaefer or conni that don't use
episode numbers. Music classification stays a human/curate-step decision.

Default fill: ``hoerspiel`` (matches the prompt's default branch).
Already-set values are left alone (idempotent).

The script also prints likely-music candidates so a human can review.
Run from the tools directory:
    uv run python scripts/backfill_content_type.py [--dry-run]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def main(dry_run: bool = False) -> int:
    paths = sorted(CURATION_DIR.glob("*.json"))
    backfilled = 0
    suspects: list[str] = []

    for p in paths:
        try:
            data = json.loads(p.read_text())
        except json.JSONDecodeError as e:
            print(f"SKIP {p.name}: {e}")
            continue

        if "content_type" not in data:
            data["content_type"] = "hoerspiel"
            backfilled += 1
            if not dry_run:
                p.write_text(json.dumps(data, indent=2, ensure_ascii=False))

        # Flag likely-music candidates for human review.
        if data.get("content_type") == "hoerspiel" and not data.get("episode_pattern"):
            included = [a for a in data.get("albums", []) if a.get("include")]
            if len(included) > 5:
                with_ep = sum(1 for a in included if a.get("episode_num"))
                if with_ep == 0:
                    suspects.append(p.stem)

    print(f"backfilled content_type=hoerspiel on {backfilled} files"
          f"{' (dry run)' if dry_run else ''}")

    if suspects:
        print()
        print("Possible music artists (no episode_pattern, no episodes extracted)")
        print("Review and set content_type='music' manually if applicable:")
        for s in suspects:
            print(f"  - {s}")

    return 0


if __name__ == "__main__":
    sys.exit(main(dry_run="--dry-run" in sys.argv))
