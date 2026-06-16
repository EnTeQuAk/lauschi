"""Manage sub_series split proposals from AI curation."""

from __future__ import annotations

import json

import click
from rich.console import Console
from rich.table import Table

from lauschi_catalog.catalog.merge_ops import (
    accept_split,
    normalize_album_ids,
    reject_split,
)
from lauschi_catalog.catalog.paths import CURATION_DIR

console = Console()


def _find_sub_index(series_id: str, label: str) -> int | None:
    """Find the current index of a sub_series by label."""
    path = CURATION_DIR / f"{series_id}.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    subs = data.get("series_facts", {}).get("sub_series", [])
    for i, s in enumerate(subs):
        if s.get("label") == label:
            return i
    return None


def _load_pending(series_id: str | None) -> list[dict]:
    """Load all series with pending split proposals."""
    if series_id:
        file_paths = [CURATION_DIR / f"{series_id}.json"]
    else:
        file_paths = sorted(CURATION_DIR.glob("*.json"))

    pending: list[dict] = []
    for path in file_paths:
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        subs = data.get("series_facts", {}).get("sub_series", [])
        if not subs:
            continue

        albums = data.get("albums", [])
        album_lookup: dict[str, dict] = {}
        for a in albums:
            album_lookup[a.get("album_id", "")] = a

        enriched_subs = []
        for sub in subs:
            resolved = normalize_album_ids(
                sub.get("album_ids", []),
                set(album_lookup),
            )
            matched = [album_lookup[aid] for aid in resolved]
            enriched_subs.append({
                "label": sub.get("label", ""),
                "reason": sub.get("reason", ""),
                "albums": sorted(
                    matched,
                    key=lambda a: (
                        a.get("episode_num") or 0,
                        a.get("provider", ""),
                    ),
                ),
            })

        pending.append({
            "series_id": data.get("id", path.stem),
            "title": data.get("title", path.stem),
            "sub_series": enriched_subs,
        })

    return pending


@click.group("splits")
def apply_splits():
    """Manage sub_series split proposals from AI curation."""


@apply_splits.command("list")
@click.argument("series_id", required=False)
@click.option("--albums", is_flag=True, help="Show album details per split")
def list_splits(series_id: str | None, albums: bool):
    """List pending split proposals."""
    pending = _load_pending(series_id)

    if not pending:
        console.print("[dim]No pending split proposals[/dim]")
        return

    for entry in pending:
        console.print(
            f"\n[bold]{entry['title']}[/bold] [dim]({entry['series_id']})[/dim]"
        )
        for sub in entry["sub_series"]:
            album_count = len(sub["albums"])
            console.print(
                f"  [cyan]{sub['label']}[/cyan] "
                f"({album_count} album{'s' if album_count != 1 else ''})"
            )
            if sub["reason"]:
                console.print(f"    {sub['reason']}")
            if albums:
                for a in sub["albums"]:
                    ep = a.get("episode_num") or "?"
                    prov = a.get("provider", "spotify")[:2]
                    console.print(f"      {ep:>3}  [{prov}] {a['title']}")

    total = sum(len(e["sub_series"]) for e in pending)
    console.print(f"\n[dim]{total} splits across {len(pending)} series[/dim]")


@apply_splits.command("show")
@click.argument("series_id")
@click.argument("label")
def show_split(series_id: str, label: str):
    """Show details of a single split proposal."""
    pending = _load_pending(series_id)
    if not pending:
        console.print(f"[red]No curation found for {series_id}[/red]")
        raise SystemExit(1)

    entry = pending[0]
    sub = next((s for s in entry["sub_series"] if s["label"] == label), None)
    if not sub:
        console.print(
            f"[red]No split '{label}' in {series_id}[/red]\n"
            f"Available: {', '.join(s['label'] for s in entry['sub_series'])}"
        )
        raise SystemExit(1)

    default_id = f"{series_id}_{label}"
    default_title = f"{entry['title']}: {label.replace('_', ' ').title()}"

    console.print(f"[bold]{entry['title']}[/bold] → [cyan]{label}[/cyan]")
    console.print(f"  Reason: {sub['reason']}")
    console.print(f"  Default ID: {default_id}")
    console.print(f"  Default title: {default_title}")
    console.print()

    table = Table(show_header=True)
    table.add_column("Ep", justify="right", style="dim", width=5)
    table.add_column("Provider", width=6)
    table.add_column("Title")

    for a in sub["albums"]:
        ep = str(a.get("episode_num") or "?")
        prov = a.get("provider", "spotify")[:2]
        table.add_row(ep, prov, a["title"])

    console.print(table)
    console.print(f"\n{len(sub['albums'])} albums")


@apply_splits.command("accept")
@click.argument("series_id")
@click.argument("label")
@click.option("--id", "new_id", help="Custom ID for the new series")
@click.option("--title", "new_title", help="Custom title for the new series")
def accept(series_id: str, label: str, new_id: str | None, new_title: str | None):
    """Accept a split proposal, creating a new series."""
    idx = _find_sub_index(series_id, label)
    if idx is None:
        console.print(f"[red]Split '{label}' not found in {series_id}[/red]")
        raise SystemExit(1)

    result = accept_split(series_id, idx, new_id=new_id, new_title=new_title)
    if result.ok:
        console.print(
            f"[green]Created {result.new_id}[/green] "
            f"from {series_id}:{label}"
        )
    else:
        console.print(f"[red]Failed: {result.error}[/red]")
        raise SystemExit(1)


@apply_splits.command("reject")
@click.argument("series_id")
@click.argument("label")
def reject(series_id: str, label: str):
    """Reject a split proposal, removing it from the curation."""
    idx = _find_sub_index(series_id, label)
    if idx is None:
        console.print(f"[red]Split '{label}' not found in {series_id}[/red]")
        raise SystemExit(1)

    result = reject_split(series_id, idx)
    if result.ok:
        console.print(
            f"[green]Rejected split '{label}' from {series_id}[/green]"
        )
    else:
        console.print(f"[red]Failed: {result.error}[/red]")
        raise SystemExit(1)


@apply_splits.command("accept-all")
@click.argument("series_id", required=False)
def accept_all(series_id: str | None):
    """Accept all pending splits (bulk mode)."""
    pending = _load_pending(series_id)
    if not pending:
        console.print("[dim]No pending split proposals[/dim]")
        return

    accepted = 0
    failed = 0
    for entry in pending:
        for sub in entry["sub_series"]:
            if not sub["albums"]:
                continue
            label = sub["label"]
            idx = _find_sub_index(entry["series_id"], label)
            if idx is None:
                continue
            result = accept_split(entry["series_id"], idx)
            if result.ok:
                console.print(
                    f"  [green]Created {result.new_id}[/green] "
                    f"from {entry['series_id']}:{label}"
                )
                accepted += 1
            else:
                console.print(
                    f"  [red]Failed {entry['series_id']}:{label}: "
                    f"{result.error}[/red]"
                )
                failed += 1

    console.print(f"\n[dim]{accepted} accepted, {failed} failed[/dim]")
