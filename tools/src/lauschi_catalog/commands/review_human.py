"""Human review: list series needing attention and suggest next steps.

Replaces the broken review-tui command that shelled out to a missing
scripts/review-curation.py. Provides a fast CLI view of what the
pipeline flagged for human eyes, with actionable commands.
"""

from __future__ import annotations

import json
from pathlib import Path

import click
from rich import box
from rich.console import Console
from rich.table import Table

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"


def _load_all() -> list[dict]:
    data: list[dict] = []
    if not CURATION_DIR.exists():
        return data
    for path in sorted(CURATION_DIR.glob("*.json")):
        try:
            data.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError):
            continue
    return data


@click.command("review-human")
@click.option("--status", "-s", multiple=True, help="Filter by status (escalated, flagged, approved, curated, ai_reviewed)")
@click.option("--detail", "-d", is_flag=True, help="Show per-series detail (concerns, fact disagreements)")
def review_human(status: tuple[str, ...], detail: bool):
    """List series that need human attention.

    After a pipeline run, some series are escalated (verify found
    incoherent output) or flagged (verify approved but disagreed with
    some facts). This command shows them with the next action to take.

    Examples: catalog-review-human (all), -s escalated, -s flagged, -d
    """
    all_data = _load_all()
    if not all_data:
        console.print("[dim]No curation files found.[/dim]")
        return

    # Normalize status filter
    want = set(s.lower() for s in status) if status else {"escalated", "flagged", "ai_verified", "curated", "ai_reviewed"}

    # Group by effective status
    need_attention: list[dict] = []
    for d in all_data:
        sid = d.get("id", "?")
        title = d.get("title", sid)
        review = d.get("review", {})
        cur_status = review.get("status", "curated")

        # Map internal statuses to human-facing buckets
        effective = cur_status
        if cur_status == "ai_verified":
            effective = "flagged"  # approved but facts disagreed
        elif cur_status == "approved":
            effective = "approved"
        elif cur_status == "escalated":
            effective = "escalated"
        elif cur_status == "ai_reviewed":
            effective = "reviewed"
        elif cur_status == "curated":
            effective = "curated"

        if not want or effective in want or cur_status in want:
            need_attention.append({
                "id": sid,
                "title": title,
                "status": effective,
                "raw_status": cur_status,
                "review": review,
                "facts": d.get("series_facts"),
                "albums": d.get("albums", []),
            })

    if not need_attention:
        console.print("[green]Nothing needs human attention.[/green]")
        return

    # Summary table
    table = Table(box=box.SIMPLE, title=f"Series needing attention ({len(need_attention)})")
    table.add_column("Status", width=12)
    table.add_column("Series", min_width=30)
    table.add_column("Action")

    for item in sorted(need_attention, key=lambda x: (x["status"] != "escalated", x["status"] != "flagged", x["title"])):
        sid = item["id"]
        title = item["title"]
        st = item["status"]
        raw = item["raw_status"]

        if st == "escalated":
            action = (
                f"mise run catalog-edit -- {sid} list\n"
                f"  then: mise run catalog-review-ai -- {sid} --force\n"
                f"  then: mise run catalog-verify -- {sid} --force"
            )
            style = "red"
        elif st == "flagged":
            action = (
                f"mise run catalog-edit -- {sid} list\n"
                f"  then: mise run catalog-verify -- {sid} --force"
            )
            style = "yellow"
        elif st == "curated":
            action = f"mise run catalog-review-ai -- {sid}"
            style = "dim"
        elif st == "reviewed":
            action = f"mise run catalog-verify -- {sid}"
            style = "blue"
        else:
            action = "(ready for apply)"
            style = "green"

        table.add_row(
            f"[{style}]{st}[/{style}]",
            f"{title}\n[dim]{sid}[/dim]",
            action,
        )

        if detail:
            concerns = item["review"].get("verification", {}).get("concerns", "")
            if concerns:
                table.add_row("", f"  [dim]Concerns: {concerns[:120]}[/dim]", "")
            facts = item.get("facts")
            if facts:
                for e in facts.get("era_boundaries", []):
                    if e.get("verify_status") == "disagreed":
                        table.add_row("", f"  [yellow]⚠ era '{e.get('label')}': {e.get('verify_reasoning', '')[:80]}[/yellow]", "")
                for g in facts.get("known_gaps", []):
                    if g.get("verify_status") == "disagreed":
                        table.add_row("", f"  [yellow]⚠ gap {g.get('number')}: {g.get('verify_reasoning', '')[:80]}[/yellow]", "")
                for s in facts.get("sub_series", []):
                    if s.get("verify_status") == "disagreed":
                        table.add_row("", f"  [yellow]⚠ sub-series '{s.get('label')}': {s.get('verify_reasoning', '')[:80]}[/yellow]", "")

    console.print(table)
    console.print()
    console.print(
        "[dim]Tip: run with --detail (-d) to see per-series concerns and fact disagreements.[/dim]"
    )
