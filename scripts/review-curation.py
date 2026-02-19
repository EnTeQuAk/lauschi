#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "textual>=8.0",
#   "pydantic>=2.0",
#   "ruamel.yaml",
# ]
# ///
"""
review-curation.py — TUI for reviewing AI-curated series data.

Reads curation JSONs from assets/catalog/curation/, presents them in a
keyboard-driven interface.  Toggle album inclusion, approve/reject series,
and write approved entries to series.yaml.

Usage
-----
  mise run catalog-review                   # launch TUI
  mise run catalog-review -- sternenschweif # jump to specific series
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from functools import partial
from pathlib import Path
from typing import Any

from pydantic import BaseModel
from ruamel.yaml import YAML
from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Hit, Hits, Provider
from textual.screen import ModalScreen, Screen
from textual.widgets import DataTable, Footer, Header, Input, Static

REPO_ROOT    = Path(__file__).parent.parent
CURATION_DIR = REPO_ROOT / "assets" / "catalog" / "curation"
SERIES_YAML  = REPO_ROOT / "assets" / "catalog" / "series.yaml"

# Status display
_STATUS_DISPLAY = {
    "pending":  "⏳ pending",
    "approved": "✅ approved",
    "rejected": "❌ rejected",
}
_STATUS_COLOR = {"approved": "green", "rejected": "red", "pending": "yellow"}


# ── Data models ────────────────────────────────────────────────────────────────

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
    reason: str = ""


class ReviewData(BaseModel):
    status: str = "pending"  # pending | approved | rejected
    reviewed_at: str | None = None
    overrides: list[ReviewOverride] = []
    notes: str = ""


class CurationFile(BaseModel):
    query: str
    model: str
    curated_at: str | None = None
    series: SeriesData
    review: ReviewData = ReviewData()


# ── Load / save ────────────────────────────────────────────────────────────────

def load_curation(path: Path) -> CurationFile:
    raw = json.loads(path.read_text())
    # Old dual-model format: {models, a, b, disagreements}
    if "models" in raw and "a" in raw:
        s = raw["a"]
        return CurationFile(
            query=s.get("title", path.stem),
            model=raw["models"][0] if raw["models"] else "unknown",
            series=SeriesData(**s),
        )
    return CurationFile(**raw)


def save_curation(path: Path, data: CurationFile) -> None:
    path.write_text(json.dumps(
        data.model_dump(exclude_none=False), indent=2, ensure_ascii=False,
    ))


def effective_albums(data: CurationFile) -> list[AlbumDecision]:
    """Apply review overrides on top of the AI decisions."""
    overrides = {o.album_id: o for o in data.review.overrides}
    result: list[AlbumDecision] = []
    for a in data.series.albums:
        if a.spotify_album_id in overrides:
            ov = overrides[a.spotify_album_id]
            result.append(a.model_copy(update={
                "include": ov.include,
                "exclude_reason": ov.reason if not ov.include else None,
            }))
        else:
            result.append(a)
    return result


def sorted_albums(
    albums: list[AlbumDecision],
    filter_mode: str = "all",
) -> list[AlbumDecision]:
    """Sort albums: included by episode, excluded by title."""
    included = sorted(
        [a for a in albums if a.include],
        key=lambda a: (a.episode_num or 999_999, a.title),
    )
    excluded = sorted(
        [a for a in albums if not a.include],
        key=lambda a: a.title,
    )
    if filter_mode == "included":
        return included
    if filter_mode == "excluded":
        return excluded
    return included + excluded


def series_summary(data: CurationFile) -> str:
    """One-line summary for command palette help text."""
    albums = effective_albums(data)
    inc = sum(1 for a in albums if a.include)
    exc = len(albums) - inc
    return f"{_STATUS_DISPLAY.get(data.review.status, data.review.status)} · {inc} inc · {exc} exc"


# ── YAML output ────────────────────────────────────────────────────────────────

def write_to_yaml(data: CurationFile) -> None:
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.default_flow_style = False
    yaml.width = 100

    albums = effective_albums(data)
    inc = sorted(
        [a for a in albums if a.include],
        key=lambda a: (a.episode_num or 999_999, a.title),
    )

    entry: dict[str, Any] = {"id": data.series.id, "title": data.series.title}
    if data.series.aliases:
        entry["aliases"] = data.series.aliases
    if data.series.keywords:
        entry["keywords"] = data.series.keywords
    entry["spotify_artist_ids"] = data.series.spotify_artist_ids
    if data.series.episode_pattern:
        entry["episode_pattern"] = data.series.episode_pattern
    if inc:
        entry["albums"] = [
            ({"id": e.spotify_album_id, "episode": e.episode_num, "title": e.title}
             if e.episode_num is not None
             else {"id": e.spotify_album_id, "title": e.title})
            for e in inc
        ]

    with SERIES_YAML.open(encoding="utf-8") as f:
        doc = yaml.load(f) or {}
    sl: list = doc.get("series", [])
    idx = next((i for i, s in enumerate(sl) if s.get("id") == data.series.id), None)
    if idx is not None:
        sl[idx] = entry
    else:
        sl.append(entry)
    with SERIES_YAML.open("w", encoding="utf-8") as f:
        yaml.dump(doc, f)


# ── Command palette ───────────────────────────────────────────────────────────

class CurationCommands(Provider):
    """Commands available in the palette (Ctrl+P)."""

    async def search(self, query: str) -> Hits:
        app = self.app
        assert isinstance(app, CurationApp)

        # "Review: <series>" — jump to any series from anywhere
        for path in sorted(CURATION_DIR.glob("*.json")):
            try:
                data = load_curation(path)
            except Exception:
                continue
            name = data.series.title or data.series.id
            command = f"📖 Review: {name}"
            if query.lower() in command.lower():
                yield Hit(
                    1.0 if query.lower() in name.lower() else 0.5,
                    command,
                    partial(self._open_review, path),
                    help=series_summary(data),
                )

        # "Review next pending"
        command = "⏭️  Review next pending"
        if query.lower() in command.lower():
            yield Hit(0.9, command, self._open_next_pending,
                      help="Open the next unreviewed series")

        # Context-aware commands when on review screen
        screen = app.screen
        if isinstance(screen, ReviewScreen):
            for cmd, action, help_text in [
                ("✅ Approve series", screen.action_approve,
                 "Write to series.yaml"),
                ("❌ Reject series", screen.action_reject,
                 "Mark for re-curation"),
                ("📝 Add notes", screen.action_notes,
                 "Add reviewer notes"),
                ("🔽 Filter: Show all", partial(screen._set_filter, "all"),
                 "Show all albums"),
                ("🟢 Filter: Included only",
                 partial(screen._set_filter, "included"),
                 "Show included albums"),
                ("🔴 Filter: Excluded only",
                 partial(screen._set_filter, "excluded"),
                 "Show excluded albums"),
            ]:
                if query.lower() in cmd.lower():
                    yield Hit(0.8, cmd, action, help=help_text)

    def _open_review(self, path: Path) -> None:
        app = self.app
        # Pop back to list if we're already reviewing something
        if isinstance(app.screen, ReviewScreen):
            app.pop_screen()
        app.push_screen(ReviewScreen(path))

    def _open_next_pending(self) -> None:
        app = self.app
        for path in sorted(CURATION_DIR.glob("*.json")):
            try:
                data = load_curation(path)
            except Exception:
                continue
            if data.review.status == "pending":
                if isinstance(app.screen, ReviewScreen):
                    app.pop_screen()
                app.push_screen(ReviewScreen(path))
                return
        app.notify("🎉 No pending reviews!", severity="information")


# ── TUI: Series list ──────────────────────────────────────────────────────────

class SeriesListScreen(Screen):
    BINDINGS = [
        Binding("enter", "open_selected", "📖 Review", key_display="Enter"),
        Binding("p", "open_pending", "⏭️  Next pending"),
        Binding("q", "quit_app", "🚪 Quit"),
    ]

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(id="series-table")
        yield Footer()

    def on_mount(self) -> None:
        self._refresh()

    def on_screen_resume(self) -> None:
        self._refresh()

    def _refresh(self) -> None:
        table = self.query_one("#series-table", DataTable)
        table.clear(columns=True)
        table.cursor_type = "row"
        table.add_column("", width=3)
        table.add_column("Series", width=28)
        table.add_column("Model", width=16)
        table.add_column("Inc", width=6)
        table.add_column("Exc", width=6)
        table.add_column("Range", width=14)
        table.add_column("Gaps", width=6)
        table.add_column("Ovr", width=6)
        table.add_column("Status", width=14)

        self._rows: list[Path] = []
        for path in sorted(CURATION_DIR.glob("*.json")):
            try:
                data = load_curation(path)
            except Exception:
                continue
            albums = effective_albums(data)
            inc_albums = [a for a in albums if a.include]
            exc = len(albums) - len(inc_albums)
            eps = sorted(
                a.episode_num for a in inc_albums if a.episode_num is not None
            )
            ep_range = f"{min(eps)}–{max(eps)}" if eps else "—"
            gap_count = (
                len(set(range(min(eps), max(eps) + 1)) - set(eps)) if eps else 0
            )
            ovr = len(data.review.overrides)
            status = data.review.status

            icon = {"approved": "✅", "rejected": "❌"}.get(status, "⏳")
            gap_str = f"⚠ {gap_count}" if gap_count else ""

            table.add_row(
                icon,
                data.series.title or data.series.id,
                data.model,
                str(len(inc_albums)), str(exc),
                ep_range,
                gap_str,
                str(ovr) if ovr else "",
                _STATUS_DISPLAY.get(status, status),
            )
            self._rows.append(path)

        if not self._rows:
            table.add_row("", "(no curations found)", "", "", "", "", "", "", "")

    def action_open_selected(self) -> None:
        table = self.query_one("#series-table", DataTable)
        idx = table.cursor_row
        if idx is not None and 0 <= idx < len(self._rows):
            self.app.push_screen(ReviewScreen(self._rows[idx]))

    def action_open_pending(self) -> None:
        for path in self._rows:
            try:
                data = load_curation(path)
            except Exception:
                continue
            if data.review.status == "pending":
                self.app.push_screen(ReviewScreen(path))
                return
        self.notify("🎉 No pending reviews!")

    # Keep RowSelected as fallback for double-click / touchpad
    @on(DataTable.RowSelected)
    def on_series_selected(self) -> None:
        self.action_open_selected()

    def action_quit_app(self) -> None:
        self.app.exit()


# ── TUI: Notes modal ──────────────────────────────────────────────────────────

class NotesModal(ModalScreen[str]):
    """Tiny modal for editing review notes."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    NotesModal {
        align: center middle;
    }
    #notes-box {
        width: 70;
        height: auto;
        max-height: 10;
        padding: 1 2;
        background: $surface;
        border: round $accent;
    }
    #notes-input {
        width: 100%;
        margin-top: 1;
    }
    """

    def __init__(self, current: str) -> None:
        super().__init__()
        self._current = current

    def compose(self) -> ComposeResult:
        from textual.containers import Vertical
        with Vertical(id="notes-box"):
            yield Static("📝 Review notes (Enter to save, Escape to cancel):")
            yield Input(value=self._current, id="notes-input")

    def on_mount(self) -> None:
        self.query_one("#notes-input", Input).focus()

    @on(Input.Submitted)
    def on_submit(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)

    def action_cancel(self) -> None:
        self.dismiss(self._current)


# ── TUI: Review screen ────────────────────────────────────────────────────────

_FILTER_ICONS = {"all": "📋", "included": "🟢", "excluded": "🔴"}

class ReviewScreen(Screen):
    BINDINGS = [
        Binding("space", "toggle", "🔀 Toggle"),
        Binding("a", "approve", "✅ Approve"),
        Binding("r", "reject", "❌ Reject"),
        Binding("f", "cycle_filter", "🔽 Filter"),
        Binding("n", "notes", "📝 Notes"),
        Binding("escape", "back", "⬅️  Back"),
        Binding("q", "back", "Back", show=False),
    ]

    DEFAULT_CSS = """
    #info {
        padding: 1 2;
        height: auto;
        max-height: 10;
        background: $surface;
        margin: 0 1;
    }
    #album-table {
        height: 1fr;
        margin: 0 1 1 1;
    }
    """

    def __init__(self, path: Path) -> None:
        super().__init__()
        self._path = path
        self._data = load_curation(path)
        self._filter = "all"
        self._album_order: list[str] = []

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static(id="info")
        yield DataTable(id="album-table")
        yield Footer()

    def on_mount(self) -> None:
        self._update_info()
        self._rebuild_table()

    # ── Info panel ────────────────────────────────────────────────────────

    def _update_info(self) -> None:
        d = self._data
        albums = effective_albums(d)
        inc = [a for a in albums if a.include]
        exc = [a for a in albums if not a.include]
        eps = sorted(a.episode_num for a in inc if a.episode_num is not None)

        status = d.review.status
        color = _STATUS_COLOR.get(status, "yellow")
        status_display = _STATUS_DISPLAY.get(status, status)

        lines = [
            f"🎧 [bold]{d.series.title}[/] · {d.model} · [{color}]{status_display}[/{color}]",
            f"🟢 {len(inc)} included · 🔴 {len(exc)} excluded"
            + (f" · 🎵 Episodes {min(eps)}–{max(eps)}" if eps else ""),
            f"🔍 Pattern: [dim]{d.series.episode_pattern or '—'}[/]",
        ]

        if eps:
            gaps = sorted(set(range(min(eps), max(eps) + 1)) - set(eps))
            if gaps:
                lines.append(
                    f"[yellow]⚠️  Gaps: {gaps[:20]}"
                    f"{'…' if len(gaps) > 20 else ''}[/]"
                )

        # Duplicate episode numbers
        by_ep: dict[int, int] = {}
        for a in inc:
            if a.episode_num is not None:
                by_ep[a.episode_num] = by_ep.get(a.episode_num, 0) + 1
        dupes = sorted(ep for ep, n in by_ep.items() if n > 1)
        if dupes:
            lines.append(f"[yellow]⚠️  Duplicate episodes: {dupes[:15]}[/]")

        if d.review.overrides:
            lines.append(f"✏️  {len(d.review.overrides)} override(s)")
        if d.review.notes:
            lines.append(f"📝 {d.review.notes}")

        icon = _FILTER_ICONS.get(self._filter, "")
        lines.append(f"[dim]{icon} Filter: {self._filter}[/]")

        self.query_one("#info", Static).update("\n".join(lines))

    # ── Album table ───────────────────────────────────────────────────────

    def _rebuild_table(self, preserve_cursor: int | None = None) -> None:
        table = self.query_one("#album-table", DataTable)
        table.clear(columns=True)
        table.cursor_type = "row"
        table.add_column("", width=4)
        table.add_column("Ep", width=6)
        table.add_column("Title", width=70)
        table.add_column("Reason", width=35)
        table.add_column("Album ID", width=24)

        albums = effective_albums(self._data)
        ov_ids = {o.album_id for o in self._data.review.overrides}
        display = sorted_albums(albums, self._filter)

        self._album_order = []
        for album in display:
            is_override = album.spotify_album_id in ov_ids
            if album.include:
                icon = "✅✏️" if is_override else "✅"
            else:
                icon = "❌✏️" if is_override else "❌"
            ep = str(album.episode_num) if album.episode_num else "—"
            reason = (album.exclude_reason or "")[:35] if not album.include else ""
            table.add_row(
                icon, ep, album.title, reason, album.spotify_album_id,
            )
            self._album_order.append(album.spotify_album_id)

        if preserve_cursor is not None:
            target = min(preserve_cursor, max(0, len(self._album_order) - 1))
            if self._album_order:
                table.move_cursor(row=target)

    # ── Actions ───────────────────────────────────────────────────────────

    def action_toggle(self) -> None:
        table = self.query_one("#album-table", DataTable)
        idx = table.cursor_row
        if idx is None or idx >= len(self._album_order):
            return

        album_id = self._album_order[idx]
        original = next(
            (a for a in self._data.series.albums
             if a.spotify_album_id == album_id),
            None,
        )
        if not original:
            return

        # Current effective state
        current_ov = next(
            (o for o in self._data.review.overrides if o.album_id == album_id),
            None,
        )
        current_include = current_ov.include if current_ov else original.include
        new_include = not current_include

        # Remove existing override
        self._data.review.overrides = [
            o for o in self._data.review.overrides if o.album_id != album_id
        ]

        # Add override only if different from original AI decision
        if new_include != original.include:
            self._data.review.overrides.append(ReviewOverride(
                album_id=album_id,
                include=new_include,
                reason="" if new_include else "Reviewer override",
            ))

        save_curation(self._path, self._data)
        self._update_info()
        self._rebuild_table(preserve_cursor=idx)

        label = "✅ included" if new_include else "❌ excluded"
        self.notify(f"{original.title[:40]} → {label}")

    def action_approve(self) -> None:
        self._data.review.status = "approved"
        self._data.review.reviewed_at = datetime.now(tz=UTC).isoformat()
        save_curation(self._path, self._data)
        write_to_yaml(self._data)
        self.notify(
            f"✅ {self._data.series.title} → series.yaml",
            severity="information",
        )
        self.app.pop_screen()

    def action_reject(self) -> None:
        self._data.review.status = "rejected"
        self._data.review.reviewed_at = datetime.now(tz=UTC).isoformat()
        save_curation(self._path, self._data)
        self.notify(
            f"❌ {self._data.series.title} rejected",
            severity="warning",
        )
        self.app.pop_screen()

    def action_cycle_filter(self) -> None:
        cycle = {"all": "included", "included": "excluded", "excluded": "all"}
        self._filter = cycle[self._filter]
        self._update_info()
        self._rebuild_table()

    def _set_filter(self, mode: str) -> None:
        """Set filter directly (used by command palette)."""
        self._filter = mode
        self._update_info()
        self._rebuild_table()

    def action_notes(self) -> None:
        def on_notes(value: str | None) -> None:
            if value is not None:
                self._data.review.notes = value
                save_curation(self._path, self._data)
                self._update_info()

        self.app.push_screen(
            NotesModal(self._data.review.notes),
            callback=on_notes,
        )

    def action_back(self) -> None:
        self.app.pop_screen()


# ── App ────────────────────────────────────────────────────────────────────────

class CurationApp(App):
    TITLE = "🎧 lauschi catalog review"
    COMMANDS = {CurationCommands}

    def __init__(self, series_id: str | None = None) -> None:
        super().__init__()
        self._initial_series = series_id

    def on_mount(self) -> None:
        self.push_screen(SeriesListScreen())
        if self._initial_series:
            path = CURATION_DIR / f"{self._initial_series}.json"
            if path.exists():
                self.push_screen(ReviewScreen(path))
            else:
                self.notify(f"Not found: {self._initial_series}", severity="error")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Review AI-curated series (TUI).")
    ap.add_argument("series_id", nargs="?", help="Jump directly to a series")
    args = ap.parse_args()
    CurationApp(series_id=args.series_id).run()


if __name__ == "__main__":
    main()
