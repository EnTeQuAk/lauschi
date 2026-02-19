#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "pydantic>=2.0",
#   "rich",
#   "ruamel.yaml",
# ]
# ///
"""
review-curation.py — Interactive review of AI-curated series data.

Reads curation JSONs from assets/catalog/curation/, presents them for human
review, records decisions, and writes approved entries to series.yaml.

Usage
-----
  mise run catalog-review                    # list all curations + status
  mise run catalog-review -- sternenschweif  # review a specific series
  mise run catalog-review -- --pending       # review next unreviewed series

Flow
----
  1. curate-series.py produces JSON (AI decisions)
  2. This script presents the JSON for review
  3. Human approves, or overrides individual albums
  4. Review decisions saved back to the JSON
  5. Approved series written to series.yaml
"""

from __future__ import annotations

import json
import re
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import BaseModel
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from ruamel.yaml import YAML

console = Console()

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
SERIES_YAML  = REPO_ROOT / "assets" / "catalog" / "series.yaml"


# ── Curation JSON schema ───────────────────────────────────────────────────────

class AlbumDecision(BaseModel):
    spotify_album_id: str
    include: bool
    episode_num: int | None = None
    title: str
    exclude_reason: str | None = None


class SeriesData(BaseModel):
    id: str
    title: str
    aliases: list[str] = []
    keywords: list[str] = []
    spotify_artist_ids: list[str] = []
    episode_pattern: str | None = None
    albums: list[AlbumDecision] = []
    curator_notes: str = ""


class ReviewOverride(BaseModel):
    album_id: str
    include: bool
    reason: str


class ReviewData(BaseModel):
    status: str = "pending"  # pending | approved | rejected
    reviewed_at: str | None = None
    overrides: list[ReviewOverride] = []
    notes: str = ""


class CurationFile(BaseModel):
    """Normalized curation file — handles both old and new formats."""
    query: str
    model: str
    curated_at: str | None = None
    series: SeriesData
    review: ReviewData = ReviewData()


def load_curation(path: Path) -> CurationFile:
    """Load and normalize a curation JSON (handles old dual-model format)."""
    raw = json.loads(path.read_text())

    # Old dual-model format: {models, a, b, disagreements}
    if "models" in raw and "a" in raw:
        series_data = raw["a"]  # use model A's output
        return CurationFile(
            query=series_data.get("title", path.stem),
            model=raw["models"][0] if raw["models"] else "unknown",
            series=SeriesData(**series_data),
        )

    # New format: {query, model, curated_at, series}
    return CurationFile(**raw)


def save_curation(path: Path, data: CurationFile) -> None:
    path.write_text(json.dumps(
        data.model_dump(exclude_none=False), indent=2, ensure_ascii=False,
    ))


# ── Helpers ────────────────────────────────────────────────────────────────────

def effective_albums(data: CurationFile) -> list[AlbumDecision]:
    """Apply review overrides to the AI decisions."""
    overrides = {o.album_id: o for o in data.review.overrides}
    result: list[AlbumDecision] = []
    for album in data.series.albums:
        if album.spotify_album_id in overrides:
            ov = overrides[album.spotify_album_id]
            result.append(album.model_copy(update={
                "include": ov.include,
                "exclude_reason": ov.reason if not ov.include else None,
            }))
        else:
            result.append(album)
    return result


def included_sorted(albums: list[AlbumDecision]) -> list[AlbumDecision]:
    return sorted(
        [a for a in albums if a.include],
        key=lambda a: (a.episode_num or 999_999, a.title),
    )


def episode_gaps(albums: list[AlbumDecision]) -> list[int]:
    eps = [a.episode_num for a in albums if a.include and a.episode_num is not None]
    if not eps:
        return []
    return sorted(set(range(min(eps), max(eps) + 1)) - set(eps))


def duplicate_episodes(albums: list[AlbumDecision]) -> list[tuple[int, list[AlbumDecision]]]:
    """Find episode numbers with multiple included albums."""
    by_ep: dict[int, list[AlbumDecision]] = {}
    for a in albums:
        if a.include and a.episode_num is not None:
            by_ep.setdefault(a.episode_num, []).append(a)
    return [(ep, dups) for ep, dups in sorted(by_ep.items()) if len(dups) > 1]


# ── Display ────────────────────────────────────────────────────────────────────

def status_color(status: str) -> str:
    return {"approved": "green", "rejected": "red"}.get(status, "yellow")


def show_list() -> None:
    """List all curation files with review status."""
    files = sorted(CURATION_DIR.glob("*.json"))
    if not files:
        console.print("[dim]No curation files in assets/catalog/curation/[/]")
        return

    t = Table(title="Curation files", box=box.ROUNDED)
    t.add_column("Series ID", min_width=25)
    t.add_column("Model", width=20)
    t.add_column("Included", width=10, justify="right")
    t.add_column("Excluded", width=10, justify="right")
    t.add_column("Overrides", width=10, justify="right")
    t.add_column("Status", width=12)

    for f in files:
        try:
            data = load_curation(f)
        except Exception as e:
            t.add_row(f.stem, "?", "?", "?", "?", f"[red]error: {e}[/]")
            continue
        albums = effective_albums(data)
        inc = sum(1 for a in albums if a.include)
        exc = len(albums) - inc
        ovr = len(data.review.overrides)
        status = data.review.status
        color = status_color(status)
        t.add_row(
            data.series.id or f.stem,
            data.model,
            str(inc), str(exc), str(ovr) if ovr else "",
            f"[{color}]{status}[/{color}]",
        )

    console.print(t)
    pending = sum(1 for f in files
                  if load_curation(f).review.status == "pending")
    if pending:
        console.print(f"\n[yellow]{pending} pending review(s).[/] "
                      "Run: mise run catalog-review -- --pending")


def show_detail(data: CurationFile) -> None:
    """Full detail view of a single curation."""
    albums = effective_albums(data)
    inc = included_sorted(albums)
    exc = [a for a in albums if not a.include]
    eps = [a.episode_num for a in inc if a.episode_num is not None]
    gaps = episode_gaps(albums)
    dupes = duplicate_episodes(albums)
    status = data.review.status
    color = status_color(status)

    console.print(Panel(
        f"[bold]{data.series.title}[/]  [dim]{data.series.id}[/]\n"
        f"Model: {data.model}\n"
        f"Artists: {', '.join(data.series.spotify_artist_ids)}\n"
        f"Pattern: {data.series.episode_pattern or '(none)'}\n"
        f"Episodes: {len(inc)} included · {len(exc)} excluded\n"
        f"Range: {min(eps) if eps else '—'}–{max(eps) if eps else '—'}\n"
        f"Status: [{color}]{status}[/{color}]"
        + (f"\nOverrides: {len(data.review.overrides)}" if data.review.overrides else ""),
        title=f"🎧 {data.series.title}",
    ))

    # Warnings
    if gaps:
        console.print(f"[yellow]⚠ Episode gaps: {gaps[:30]}"
                      f"{'…' if len(gaps) > 30 else ''}[/]")
    if dupes:
        console.print(f"[yellow]⚠ Duplicate episodes: "
                      f"{[ep for ep, _ in dupes[:10]]}[/]")

    # Included episodes
    t = Table(box=box.SIMPLE, title=f"Included ({len(inc)})")
    t.add_column("#", width=5, justify="right")
    t.add_column("Ep", width=5, justify="right")
    t.add_column("Title", min_width=45)
    t.add_column("ID", width=24)
    overridden_ids = {o.album_id for o in data.review.overrides}
    for i, ep in enumerate(inc, 1):
        marker = " ✎" if ep.spotify_album_id in overridden_ids else ""
        t.add_row(
            str(i),
            str(ep.episode_num) if ep.episode_num else "—",
            ep.title[:55] + marker,
            ep.spotify_album_id,
        )
    console.print(t)

    # Excluded
    if exc:
        t2 = Table(box=box.SIMPLE, title=f"Excluded ({len(exc)})")
        t2.add_column("#", width=5, justify="right")
        t2.add_column("Title", min_width=40)
        t2.add_column("Reason", min_width=25)
        t2.add_column("ID", width=24)
        for i, ex in enumerate(exc, 1):
            marker = " ✎" if ex.spotify_album_id in overridden_ids else ""
            t2.add_row(
                str(i),
                ex.title[:50] + marker,
                (ex.exclude_reason or "")[:30],
                ex.spotify_album_id,
            )
        console.print(t2)

    if data.series.curator_notes:
        console.print(f"\n[dim]AI notes: {data.series.curator_notes[:300]}[/]")
    if data.review.notes:
        console.print(f"\n[bold]Review notes:[/] {data.review.notes}")


# ── Interactive review ─────────────────────────────────────────────────────────

def prompt_choice(prompt: str, choices: list[str]) -> str:
    """Prompt for a choice, return the selected value."""
    while True:
        raw = console.input(f"{prompt} [{'/'.join(choices)}]: ").strip().lower()
        if raw in choices:
            return raw
        console.print(f"[red]Choose one of: {', '.join(choices)}[/]")


def review_interactive(path: Path, data: CurationFile) -> None:
    """Interactive review session."""
    show_detail(data)
    console.print()

    while True:
        console.print("[bold]Actions:[/]")
        console.print("  [green]a[/]pprove  — accept and write to series.yaml")
        console.print("  [red]r[/]eject   — mark as rejected (re-curate later)")
        console.print("  [yellow]i[/]nclude  — override: include an excluded album")
        console.print("  [yellow]e[/]xclude  — override: exclude an included album")
        console.print("  [blue]n[/]otes   — add review notes")
        console.print("  [blue]v[/]iew    — show detail again")
        console.print("  [dim]q[/]uit    — save overrides, don't approve yet")

        action = prompt_choice("\nAction", ["a", "r", "i", "e", "n", "v", "q"])

        if action == "a":
            data.review.status = "approved"
            data.review.reviewed_at = datetime.now(tz=UTC).isoformat()
            save_curation(path, data)
            write_to_yaml(data)
            console.print("[green]✅ Approved and written to series.yaml[/]")
            return

        elif action == "r":
            data.review.status = "rejected"
            data.review.reviewed_at = datetime.now(tz=UTC).isoformat()
            save_curation(path, data)
            console.print("[red]❌ Rejected. Re-curate with: "
                          f"mise run catalog-curate -- \"{data.query}\"[/]")
            return

        elif action == "i":
            _override_album(data, include=True)
            save_curation(path, data)

        elif action == "e":
            _override_album(data, include=False)
            save_curation(path, data)

        elif action == "n":
            note = console.input("Review notes: ").strip()
            if note:
                data.review.notes = note
                save_curation(path, data)
                console.print("[dim]Notes saved.[/]")

        elif action == "v":
            show_detail(data)

        elif action == "q":
            save_curation(path, data)
            console.print("[dim]Saved (still pending).[/]")
            return


def _override_album(data: CurationFile, *, include: bool) -> None:
    """Add an override for a specific album."""
    albums = effective_albums(data)
    # Show candidates (excluded if including, included if excluding)
    candidates = [a for a in albums if a.include != include]
    if not candidates:
        label = "excluded" if include else "included"
        console.print(f"[dim]No {label} albums to override.[/]")
        return

    label = "excluded" if include else "included"
    console.print(f"\nCurrently {label} albums:")
    for i, a in enumerate(candidates, 1):
        ep = f"Ep {a.episode_num}" if a.episode_num else "no ep"
        extra = f" — {a.exclude_reason}" if a.exclude_reason else ""
        console.print(f"  {i:>3}. {a.title[:50]}  [{ep}]{extra}")

    raw = console.input(f"\nAlbum number (1-{len(candidates)}, or 'c' to cancel): ").strip()
    if raw.lower() == "c":
        return
    try:
        idx = int(raw) - 1
        if not 0 <= idx < len(candidates):
            raise ValueError
    except ValueError:
        console.print("[red]Invalid number.[/]")
        return

    album = candidates[idx]
    reason = ""
    if not include:
        reason = console.input("Exclude reason: ").strip()

    # Remove existing override for this album if any
    data.review.overrides = [
        o for o in data.review.overrides
        if o.album_id != album.spotify_album_id
    ]
    data.review.overrides.append(ReviewOverride(
        album_id=album.spotify_album_id,
        include=include,
        reason=reason,
    ))
    action = "included" if include else "excluded"
    console.print(f"[green]✓ Override: {album.title[:40]} → {action}[/]")


# ── YAML output ────────────────────────────────────────────────────────────────

def to_yaml_entry(data: CurationFile) -> dict[str, Any]:
    """Build a series.yaml entry from reviewed curation data."""
    series = data.series
    albums = effective_albums(data)
    inc = included_sorted(albums)

    d: dict[str, Any] = {"id": series.id, "title": series.title}
    if series.aliases:
        d["aliases"] = series.aliases
    if series.keywords:
        d["keywords"] = series.keywords
    d["spotify_artist_ids"] = series.spotify_artist_ids
    if series.episode_pattern:
        d["episode_pattern"] = series.episode_pattern
    if inc:
        d["albums"] = [
            ({"id": e.spotify_album_id, "episode": e.episode_num, "title": e.title}
             if e.episode_num is not None
             else {"id": e.spotify_album_id, "title": e.title})
            for e in inc
        ]
    return d


def write_to_yaml(data: CurationFile) -> None:
    """Write an approved series entry to series.yaml."""
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False
    yaml.width = 100

    entry = to_yaml_entry(data)

    with SERIES_YAML.open(encoding="utf-8") as f:
        doc = yaml.load(f) or {}
    sl: list = doc.get("series", [])

    idx = next((i for i, s in enumerate(sl) if s.get("id") == data.series.id), None)
    if idx is not None:
        sl[idx] = entry
        console.print(f"[yellow]Replaced {data.series.id} in series.yaml[/]")
    else:
        sl.append(entry)
        console.print(f"[green]Appended {data.series.id} to series.yaml[/]")

    with SERIES_YAML.open("w", encoding="utf-8") as f:
        yaml.dump(doc, f)


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description="Review AI-curated series data.")
    ap.add_argument("series_id", nargs="?", help="Series ID to review")
    ap.add_argument("--pending", action="store_true",
                    help="Review the next pending series")
    ap.add_argument("--list", action="store_true",
                    help="List all curations (default when no args)")
    args = ap.parse_args()

    if args.pending:
        for f in sorted(CURATION_DIR.glob("*.json")):
            data = load_curation(f)
            if data.review.status == "pending":
                review_interactive(f, data)
                return
        console.print("[green]No pending reviews.[/]")
        return

    if args.series_id:
        path = CURATION_DIR / f"{args.series_id}.json"
        if not path.exists():
            console.print(f"[red]Not found: {path}[/]")
            console.print(f"[dim]Available: "
                          f"{', '.join(f.stem for f in CURATION_DIR.glob('*.json'))}[/]")
            sys.exit(1)
        data = load_curation(path)
        review_interactive(path, data)
        return

    show_list()


if __name__ == "__main__":
    main()
