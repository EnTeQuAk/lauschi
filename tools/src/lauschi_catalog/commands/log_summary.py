"""Mine a catalog-pipeline log for per-series re-run signals.

A pipeline run leaves a rich set of signals scattered across thousands
of log lines: which series failed and why, where the metadata agent
chose a low-coverage pattern, when the id-lock helper saved us from a
typo'd filename, which review verdicts deferred to a human, which
verify checks escalated. Reading those lines manually is hopeless.

This command parses the log, attributes signals to specific series,
classifies each series by health, and emits a per-series report. Bare
``--ids`` output is designed to pipe straight back into curate/review:

    lauschi-catalog log-summary --ids --filter failed | \\
        xargs -I{} mise run catalog-curate -- {} --force

Health classification (highest severity wins):

- ``failed``     — curate or verify hit a hard error; needs re-run
- ``escalated``  — verify produced a human-review verdict
- ``attention``  — review deferred a category, or a coverage warning
                   fired, or a pattern was revised mid-run
- ``info``       — id lock or search disambiguation fired (benign)
- ``healthy``    — no flags
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Any, Iterable

import click
from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from lauschi_catalog.catalog.loader import load_catalog

console = Console()

REPO_ROOT = Path(__file__).parent.parent.parent.parent.parent
LOG_DIR = REPO_ROOT / "logs" / "catalog"


# ── Health levels ─────────────────────────────────────────────────────────


class Health(StrEnum):
    HEALTHY = "healthy"
    INFO = "info"
    ATTENTION = "attention"
    ESCALATED = "escalated"
    FAILED = "failed"


# Severity order used for sorting / "highest wins" classification.
_HEALTH_ORDER: dict[Health, int] = {
    Health.HEALTHY: 0,
    Health.INFO: 1,
    Health.ATTENTION: 2,
    Health.ESCALATED: 3,
    Health.FAILED: 4,
}

_HEALTH_STYLE: dict[Health, str] = {
    Health.HEALTHY: "green",
    Health.INFO: "cyan",
    Health.ATTENTION: "yellow",
    Health.ESCALATED: "magenta",
    Health.FAILED: "red",
}


# ── Per-series report ─────────────────────────────────────────────────────


@dataclass
class SeriesReport:
    """Everything we learned about one series in this pipeline run.

    Most fields default to their "not-seen" sentinel so a partial run
    (curate-only, review-only, etc.) doesn't synthesize false signals.
    """

    series_id: str
    title: str = ""

    # Curate phase
    curate_seen: bool = False
    curate_status: str = "not_seen"  # success | failed | not_seen
    curate_failure_kind: str | None = None  # http_404 | http_400 | timeout | other
    curate_failure_detail: str | None = None
    total_albums: int | None = None
    flow: str | None = None  # single-agent | batched

    # Pattern signals (curate)
    pattern_coverage_warning: bool = False
    pattern_coverage_matched: int | None = None
    pattern_coverage_total: int | None = None
    pattern_revised_mid_run: bool = False
    pattern_initial: str | None = None
    pattern_final: str | None = None
    pattern_re_extracted: int | None = None

    # ID/disambiguation signals (curate)
    id_lock_fired: bool = False
    id_lock_from: str | None = None
    search_disambiguation: bool = False
    search_disambiguation_alt: str | None = None

    # Review phase
    review_seen: bool = False
    review_status: str = "not_seen"  # success | skipped | not_seen
    review_overrides: int = 0
    review_splits: int = 0
    review_added: int = 0
    review_pattern_update: bool = False
    review_verdicts: dict[str, str] = field(default_factory=dict)
    review_deferred_categories: list[str] = field(default_factory=list)
    review_coerced_categories: list[str] = field(default_factory=list)
    review_summary: str = ""

    # Verify phase
    verify_seen: bool = False
    verify_status: str = "not_seen"  # approved | escalated | failed | not_seen
    verify_concerns: str = ""

    # Apply phase
    apply_seen: bool = False
    apply_status: str | None = None  # applied | refused | not_seen


# ── Parser ────────────────────────────────────────────────────────────────


# Curate phase
_RE_PHASE = re.compile(r"^Step (\d)/5: (.+?)\.\.\.")
_RE_CURATE_HEADER = re.compile(r"^\(\d+/\d+\) (.+?) \(\d+ done, \d+ failed, \d+ skipped\)$")
_RE_FLOW = re.compile(r"^\s+(\d+) albums — using (single-agent|batched) flow$")
_RE_TOTAL = re.compile(r"^\s+Total: (\d+) albums across \d+ providers")
# Both unindented (curate) and indented (review's "  Saved to ...") forms.
_RE_SAVE = re.compile(r"^\s*Saved to .*/curation/([a-z][a-z0-9_]*)\.json")
_RE_FAILURE = re.compile(r"^Failed to curate (.+?): (.+)$")
_RE_ID_LOCK = re.compile(r"Locked id to canonical: '([^']+)' → '([^']+)'")
_RE_DISAMBIG = re.compile(r"\bchose\b\s+(\S.+?)\s+\[\S+\]\s+\(also matched: ([^)]+)\)")
_RE_PATTERN_COV_WARN = re.compile(
    r"Low metadata-phase pattern coverage: (\d+)/(\d+)",
)
_RE_PATTERN_REVISED = re.compile(
    r"Pattern revised mid-run: (.+?) → (.+?)\. Re-extracted (\d+) episode",
)

# Review phase
_RE_REVIEWING = re.compile(r"^Reviewing (.+?)\.{3}$")
_RE_REVIEW_SKIP = re.compile(
    r"^Skipping ([a-z][a-z0-9_]*) \(already (approved|ai_verified); use --force",
)
_RE_REVIEW_COUNTS = re.compile(
    r"^\s+(\d+) overrides, (\d+) splits, (\d+) added(?:, (pattern_update))?",
)
_RE_REVIEW_VERDICTS = re.compile(
    r"^\s+dup:(\S+)\s+\|\s+sub:(\S+)\s+\|\s+gap:(\S+)\s+\|\s+pat:(\S+)\s+\|\s+out:(\S+)\s+\|\s+xprov:(\S+)",
)
_RE_REVIEW_COERCED = re.compile(
    r"Coerced inconsistent verdicts to deferred_to_human:\s+(.+)$",
)
_RE_REVIEW_SUMMARY = re.compile(r"^\s+Summary: (.+)$")

# Verify phase
_RE_VERIFYING = re.compile(r"^Verifying ([a-z][a-z0-9_]*)\.{3}")
_RE_VERIFY_APPROVED = re.compile(r"^\s+✓ Approved")
_RE_VERIFY_ESCALATED = re.compile(r"^\s+⚠ Escalated")
_RE_VERIFY_CONCERNS = re.compile(r"^\s+Concerns: (.+)$")


_VERDICT_CATEGORIES = (
    "duplicates", "sub_series", "gaps", "pattern", "outliers", "cross_provider",
)

_PHASE_NAMES = {
    "curate": "Step 1 Curate",
    "review": "Step 2 Review",
    "verify": "Step 3 Verify",
    "apply":  "Step 4 Apply",
}


@dataclass
class PipelineState:
    """Where the pipeline is *right now*, derived from the log tail.

    A complement to per-series reports: those tell you *what* happened
    to each series; this tells you *which phase* the pipeline is
    currently working in and what it's doing this minute. Useful for
    answering 'is it still running, and how far along?' without
    having to scroll the log by hand.
    """

    last_phase: str | None = None
    last_event_line: str = ""
    # Active series in the most recent phase, parsed from the latest
    # 'Reviewing X...' / 'Verifying X...' / curate header line.
    active_curate_title: str | None = None
    active_review_title: str | None = None
    active_verify_id: str | None = None


def _classify_failure(detail: str) -> str:
    """Map a curate failure message to a coarse kind."""
    if "TimeoutError" in detail:
        return "timeout"
    if "404" in detail:
        return "http_404"
    if "400" in detail:
        return "http_400"
    return "other"


def parse_log(log_path: Path) -> dict[str, SeriesReport]:
    """Parse a pipeline log and return one SeriesReport per series.

    The parser walks the log line-by-line tracking the active phase
    and the current series context. Curate/review headers carry a
    title (no id), so signals buffer under a temporary title-key
    until the matching ``Saved to .../{id}.json`` line resolves the
    id and we migrate the buffered report.

    For curate FAILURES (no save line), the title persists as the
    key. Title-keyed reports are reconciled against series.yaml at
    the end so the user sees canonical ids whenever possible.
    """
    reports: dict[str, SeriesReport] = {}
    by_title: dict[str, SeriesReport] = {}

    phase: str | None = None
    # Records by REFERENCE so post-save signals (verdicts, summary)
    # can still attribute to the just-resolved series. Set when a
    # phase-header line is parsed; cleared when the next header
    # arrives or the phase changes.
    cur_curate: SeriesReport | None = None
    cur_review: SeriesReport | None = None
    cur_verify: SeriesReport | None = None

    def _resolve_save(sid: str, title_keyed: SeriesReport | None) -> SeriesReport:
        """Migrate a title-keyed report to its resolved id-keyed slot.

        Returns the live report (may be a different object from
        ``title_keyed`` when a same-id report already exists from
        another phase and we merged into it).
        """
        if title_keyed is not None:
            title_keyed.series_id = sid
            existing = reports.get(sid)
            if existing is not None:
                # Merge: happens when curate already wrote the report
                # (saved its own line) and review now arrives with its
                # own title-keyed accumulation. Prefer existing fields
                # when they're populated.
                _merge_into(existing, title_keyed)
                report = existing
            else:
                report = title_keyed
                reports[sid] = report
            # Drop the title-keyed slot so further signals on the same
            # title (defensive) start fresh.
            for t, r in list(by_title.items()):
                if r is title_keyed:
                    del by_title[t]
                    break
        else:
            report = reports.setdefault(sid, SeriesReport(series_id=sid))
        return report

    for raw in log_path.read_text(errors="replace").splitlines():
        line = raw.rstrip()
        if not line:
            continue

        # Phase markers
        m = _RE_PHASE.match(line)
        if m:
            step = m.group(1)
            phase = {"1": "curate", "2": "review", "3": "verify", "4": "apply"}.get(step)
            cur_curate = cur_review = cur_verify = None
            continue

        # ── Curate phase ──────────────────────────────────────────────
        m = _RE_CURATE_HEADER.match(line)
        if m and phase != "review" and phase != "verify":
            title = m.group(1)
            phase = "curate"
            cur_curate = by_title.setdefault(
                title, SeriesReport(series_id="", title=title),
            )
            cur_curate.curate_seen = True
            if not cur_curate.title:
                cur_curate.title = title
            continue

        if phase == "curate" or cur_curate is not None:
            m = _RE_FLOW.match(line)
            if m and cur_curate:
                cur_curate.total_albums = int(m.group(1))
                cur_curate.flow = m.group(2)
                continue
            m = _RE_TOTAL.match(line)
            if m and cur_curate and cur_curate.total_albums is None:
                cur_curate.total_albums = int(m.group(1))
                continue
            m = _RE_ID_LOCK.search(line)
            if m and cur_curate:
                cur_curate.id_lock_fired = True
                cur_curate.id_lock_from = m.group(1)
                # The "to" id is canonical; save line migrates the record.
                continue
            m = _RE_DISAMBIG.search(line)
            if m and cur_curate:
                cur_curate.search_disambiguation = True
                cur_curate.search_disambiguation_alt = m.group(2)
                continue
            m = _RE_PATTERN_COV_WARN.search(line)
            if m and cur_curate:
                cur_curate.pattern_coverage_warning = True
                cur_curate.pattern_coverage_matched = int(m.group(1))
                cur_curate.pattern_coverage_total = int(m.group(2))
                continue
            m = _RE_PATTERN_REVISED.search(line)
            if m and cur_curate:
                cur_curate.pattern_revised_mid_run = True
                cur_curate.pattern_initial = m.group(1).strip()
                cur_curate.pattern_final = m.group(2).strip()
                cur_curate.pattern_re_extracted = int(m.group(3))
                continue
            m = _RE_FAILURE.match(line)
            if m:
                title = m.group(1)
                detail = m.group(2)
                # Failure may arrive without a matching curate header.
                r = by_title.setdefault(title, SeriesReport(series_id="", title=title))
                r.curate_seen = True
                r.curate_status = "failed"
                r.curate_failure_detail = detail.strip()
                r.curate_failure_kind = _classify_failure(detail)
                cur_curate = None
                continue
            m = _RE_SAVE.match(line)
            if m and phase == "curate":
                sid = m.group(1)
                r = _resolve_save(sid, cur_curate)
                r.curate_status = "success"
                cur_curate = r  # post-save signals (none for curate today) attribute here
                continue

        # ── Review phase ──────────────────────────────────────────────
        m = _RE_REVIEWING.match(line)
        if m:
            title = m.group(1)
            phase = "review"
            cur_review = by_title.setdefault(
                title, SeriesReport(series_id="", title=title),
            )
            cur_review.review_seen = True
            if not cur_review.title:
                cur_review.title = title
            continue
        m = _RE_REVIEW_SKIP.match(line)
        if m:
            sid = m.group(1)
            r = reports.setdefault(sid, SeriesReport(series_id=sid))
            r.review_seen = True
            r.review_status = "skipped"
            continue

        if phase == "review" and cur_review is not None:
            m = _RE_REVIEW_COUNTS.match(line)
            if m:
                cur_review.review_overrides = int(m.group(1))
                cur_review.review_splits = int(m.group(2))
                cur_review.review_added = int(m.group(3))
                cur_review.review_pattern_update = m.group(4) is not None
                continue
            m = _RE_REVIEW_VERDICTS.match(line)
            if m:
                # Verdicts come AFTER save in review; cur_review must
                # remain pointing at the just-saved record so this
                # attribution works.
                for cat, v in zip(_VERDICT_CATEGORIES, m.groups()):
                    cur_review.review_verdicts[cat] = v
                    if v == "deferred_to_human":
                        cur_review.review_deferred_categories.append(cat)
                continue
            m = _RE_REVIEW_COERCED.search(line)
            if m:
                cats = [c.strip() for c in m.group(1).split(",")]
                cur_review.review_coerced_categories.extend(cats)
                continue
            m = _RE_REVIEW_SUMMARY.match(line)
            if m and not cur_review.review_summary:
                cur_review.review_summary = m.group(1).strip()
                continue
            m = _RE_SAVE.match(line)
            if m:
                sid = m.group(1)
                cur_review = _resolve_save(sid, cur_review)
                cur_review.review_status = "success"
                # NOTE: don't reset cur_review here; verdicts + summary
                # follow the Save line in review's output.
                continue

        # ── Verify phase ──────────────────────────────────────────────
        m = _RE_VERIFYING.match(line)
        if m:
            sid = m.group(1)
            phase = "verify"
            cur_verify = reports.setdefault(sid, SeriesReport(series_id=sid))
            cur_verify.verify_seen = True
            continue
        if phase == "verify" and cur_verify is not None:
            if _RE_VERIFY_APPROVED.match(line):
                cur_verify.verify_status = "approved"
                continue
            if _RE_VERIFY_ESCALATED.match(line):
                cur_verify.verify_status = "escalated"
                continue
            m = _RE_VERIFY_CONCERNS.match(line)
            if m and not cur_verify.verify_concerns:
                cur_verify.verify_concerns = m.group(1).strip()
                continue

    # Reconcile remaining title-keyed reports against series.yaml.
    # Curate failures don't produce a save line, so the title remains
    # the only handle. Lookup by title gives users canonical ids.
    title_to_id = _build_title_to_id_map()
    for title, r in list(by_title.items()):
        sid = title_to_id.get(title)
        if sid:
            r.series_id = sid
            reports[sid] = r
        else:
            # Unknown to series.yaml — surface anyway under a stable key
            # derived from title so the user sees the failure exists.
            r.series_id = _slug(title)
            reports[r.series_id] = r

    return reports


_TITLE_TO_ID_CACHE: dict[str, str] | None = None
_CATALOG_SIZE_CACHE: int | None = None


@dataclass
class PhaseCounts:
    """Per-phase tally derived from per-series reports."""
    success: int = 0
    failed: int = 0
    skipped: int = 0
    not_seen: int = 0
    # Phase-specific extras (escalated only meaningful for verify, etc.)
    escalated: int = 0

    @property
    def reached(self) -> int:
        """Series that this phase touched (success + failed + skipped)."""
        return self.success + self.failed + self.skipped + self.escalated


def _count_phase(
    reports: dict[str, SeriesReport], phase: str,
) -> PhaseCounts:
    """Count phase outcomes across all reports."""
    counts = PhaseCounts()
    for r in reports.values():
        if phase == "curate":
            status = r.curate_status
        elif phase == "review":
            status = r.review_status
        elif phase == "verify":
            status = r.verify_status
        else:
            status = "not_seen"

        if status == "success" or status == "approved" or status == "applied":
            counts.success += 1
        elif status == "escalated":
            counts.escalated += 1
        elif status == "failed":
            counts.failed += 1
        elif status == "skipped":
            counts.skipped += 1
        else:
            counts.not_seen += 1
    return counts


def _scan_pipeline_state(log_path: Path) -> PipelineState:
    """Tail-scan the log to figure out which phase is currently active
    and what series the agents are working on right now.

    The full parse already tracks this internally but discards it
    when it returns. Re-running the scan keeps the data path simple
    (parse_log stays a pure dict producer); the cost is one extra
    walk over the log, which is cheap relative to the LLM-bound
    pipeline run that produced it.
    """
    state = PipelineState()
    for raw in log_path.read_text(errors="replace").splitlines():
        line = raw.rstrip()
        if not line:
            continue

        m = _RE_PHASE.match(line)
        if m:
            step = m.group(1)
            state.last_phase = {
                "1": "curate", "2": "review", "3": "verify", "4": "apply",
            }.get(step)
            continue

        m = _RE_CURATE_HEADER.match(line)
        if m and state.last_phase != "review" and state.last_phase != "verify":
            state.last_phase = "curate"
            state.active_curate_title = m.group(1)
            state.last_event_line = line
            continue
        m = _RE_REVIEWING.match(line)
        if m:
            state.last_phase = "review"
            state.active_review_title = m.group(1)
            state.last_event_line = line
            continue
        m = _RE_VERIFYING.match(line)
        if m:
            state.last_phase = "verify"
            state.active_verify_id = m.group(1)
            state.last_event_line = line
            continue
    return state


def _build_title_to_id_map() -> dict[str, str]:
    """Map every catalog entry's title to its canonical id.

    Cached on first call. parse_log is fast on its own; reloading
    series.yaml on every invocation dominates test wall-time and
    isn't useful — series.yaml doesn't change inside one process.
    Tests can reset by calling ``_clear_title_cache()``.

    Note: shared titles (e.g., 'Bibi Blocksberg' for the main series
    AND its sub-series) collapse here because dicts hold one value
    per key. Use :func:`_catalog_size` for the true total count.
    """
    global _TITLE_TO_ID_CACHE, _CATALOG_SIZE_CACHE
    if _TITLE_TO_ID_CACHE is None:
        try:
            entries = list(load_catalog())
            _TITLE_TO_ID_CACHE = {e.title: e.id for e in entries}
            _CATALOG_SIZE_CACHE = len(entries)
        except Exception:
            _TITLE_TO_ID_CACHE = {}
            _CATALOG_SIZE_CACHE = 0
    return _TITLE_TO_ID_CACHE


def _catalog_size() -> int:
    """Total catalog entries (counts shared-title duplicates)."""
    _build_title_to_id_map()  # populates both caches
    return _CATALOG_SIZE_CACHE or 0


def _clear_title_cache() -> None:
    """Drop the cached title→id map and size (test hook)."""
    global _TITLE_TO_ID_CACHE, _CATALOG_SIZE_CACHE
    _TITLE_TO_ID_CACHE = None
    _CATALOG_SIZE_CACHE = None


_SLUG_RE = re.compile(r"[^a-z0-9]+")


def _slug(text: str) -> str:
    """Fallback id for failures whose title isn't in series.yaml."""
    return _SLUG_RE.sub("_", text.lower()).strip("_") or "unknown"


def _merge_into(target: SeriesReport, source: SeriesReport) -> None:
    """Merge source's populated fields into target. Used when the
    same series surfaces in two phases at different points."""
    for field_name, value in source.__dict__.items():
        if field_name == "series_id":
            continue
        # Lists/dicts: extend/update if target's is empty
        if isinstance(value, list) and not getattr(target, field_name):
            setattr(target, field_name, list(value))
        elif isinstance(value, dict) and not getattr(target, field_name):
            setattr(target, field_name, dict(value))
        elif (
            value not in (None, False, "", "not_seen", 0)
            and getattr(target, field_name) in (None, False, "", "not_seen", 0)
        ):
            setattr(target, field_name, value)


# ── Health classification ─────────────────────────────────────────────────


def classify(r: SeriesReport) -> Health:
    """Return the highest-severity health level supported by signals."""
    if r.curate_status == "failed":
        return Health.FAILED
    if r.verify_status == "escalated":
        return Health.ESCALATED
    if r.verify_status == "failed":
        return Health.FAILED
    if (
        r.review_deferred_categories
        or r.review_coerced_categories
        or r.pattern_coverage_warning
        or r.pattern_revised_mid_run
    ):
        return Health.ATTENTION
    if r.id_lock_fired or r.search_disambiguation:
        return Health.INFO
    return Health.HEALTHY


def collect_flags(r: SeriesReport) -> list[str]:
    """Short tags describing the active signals on a report.

    Used in pretty-table cells so a glance shows what's flagged
    without opening the per-series detail view.
    """
    flags: list[str] = []
    if r.curate_status == "failed":
        flags.append(f"curate-fail:{r.curate_failure_kind or 'other'}")
    if r.pattern_coverage_warning:
        m, t = r.pattern_coverage_matched, r.pattern_coverage_total
        if m is not None and t:
            flags.append(f"low-coverage:{m}/{t}")
        else:
            flags.append("low-coverage")
    if r.pattern_revised_mid_run:
        flags.append(f"pattern-revised(+{r.pattern_re_extracted})")
    if r.id_lock_fired:
        flags.append(f"id-locked({r.id_lock_from})")
    if r.search_disambiguation:
        flags.append("disambig")
    if r.review_deferred_categories:
        flags.append("defer:" + ",".join(r.review_deferred_categories))
    if r.review_coerced_categories:
        flags.append("coerce:" + ",".join(set(r.review_coerced_categories)))
    if r.verify_status == "escalated":
        flags.append("verify-escalated")
    return flags


# ── Renderers ─────────────────────────────────────────────────────────────


def _phase_cell(status: str) -> str:
    if status == "success":
        return "[green]✓[/green]"
    if status == "skipped":
        return "[dim]–[/dim]"
    if status == "failed":
        return "[red]✗[/red]"
    if status in ("approved",):
        return "[green]✓[/green]"
    if status == "escalated":
        return "[magenta]⚠[/magenta]"
    if status == "applied":
        return "[green]✓[/green]"
    if status == "refused":
        return "[yellow]∅[/yellow]"
    return "[dim]·[/dim]"


_PHASE_ORDER = ("curate", "review", "verify", "apply")


def _phase_state(
    phase: str,
    last_phase: str | None,
    counts: PhaseCounts,
) -> str:
    """One of: 'done', 'in_progress', 'pending'.

    Encodes the high-level question 'where are we in the pipeline?'
    by deriving phase status from the active-phase pointer rather
    than from raw counts, which can overshoot when orphan curation
    files get reviewed/verified outside series.yaml's bounds.
    """
    if last_phase is None:
        return "pending" if counts.reached == 0 else "done"
    last_idx = _PHASE_ORDER.index(last_phase) if last_phase in _PHASE_ORDER else -1
    this_idx = _PHASE_ORDER.index(phase)
    if this_idx < last_idx:
        return "done"
    if this_idx == last_idx:
        # Active phase. Treat as done iff every phase before it has
        # touched series and this phase has nothing left to start —
        # but we can't know that without comparing to the catalog.
        # Practical compromise: 'in_progress' until the next phase
        # marker fires.
        return "in_progress"
    return "pending"


def render_progress(
    reports: dict[str, SeriesReport],
    state: PipelineState,
    *,
    catalog_size: int | None = None,
) -> Panel:
    """Pipeline-progress panel: phase-by-phase status with the
    active series called out.

    Phase status (done / in_progress / pending) comes from the
    last-seen phase header in the log — that's the reliable signal
    even when reach counts exceed catalog_size due to orphan
    curation files.
    """
    lines: list[str] = []
    cat_size = catalog_size or 0

    for phase_key in _PHASE_ORDER:
        counts = _count_phase(reports, phase_key)
        status = _phase_state(phase_key, state.last_phase, counts)

        marker = {
            "done":        "[green]✓ done       [/green]",
            "in_progress": "[cyan]⠿ in progress[/cyan]",
            "pending":     "[dim]· pending    [/dim]",
        }[status]

        bits: list[str] = []
        if counts.success:
            bits.append(f"[green]{counts.success} ok[/green]")
        if counts.escalated:
            bits.append(f"[magenta]{counts.escalated} escalated[/magenta]")
        if counts.failed:
            bits.append(f"[red]{counts.failed} failed[/red]")
        if counts.skipped:
            bits.append(f"[dim]{counts.skipped} skipped[/dim]")
        breakdown = ", ".join(bits) if bits else "[dim]—[/dim]"

        # Reach as a fraction is informational. Show it only when
        # it's a sensible ratio (numerator <= catalog size). Beyond
        # that, show the raw count + an orphan note so the over-
        # shoot is explained rather than mysterious.
        if cat_size and counts.reached <= cat_size:
            ratio = f"{counts.reached}/{cat_size}"
        elif cat_size:
            extra = counts.reached - cat_size
            ratio = f"{counts.reached} ([dim]+{extra} orphans[/dim])"
        else:
            ratio = str(counts.reached)

        active = ""
        if status == "in_progress":
            if phase_key == "curate" and state.active_curate_title:
                active = f"  [cyan]→ {state.active_curate_title}[/cyan]"
            elif phase_key == "review" and state.active_review_title:
                active = f"  [cyan]→ {state.active_review_title}[/cyan]"
            elif phase_key == "verify" and state.active_verify_id:
                active = f"  [cyan]→ {state.active_verify_id}[/cyan]"

        label = _PHASE_NAMES[phase_key]
        lines.append(
            f"  {label:<14} {marker}  {ratio:<24} {breakdown}{active}",
        )

    return Panel(
        "\n".join(lines),
        title="Pipeline progress",
        border_style="cyan",
    )


def render_pretty(
    reports: dict[str, SeriesReport],
    *,
    filter_levels: set[Health] | None = None,
) -> Iterable[Any]:
    """Yield rich renderables for the table view."""
    classified = [(classify(r), r) for r in reports.values()]
    if filter_levels:
        classified = [(h, r) for h, r in classified if h in filter_levels]
    classified.sort(key=lambda pair: (-_HEALTH_ORDER[pair[0]], pair[1].series_id))

    counts: dict[Health, int] = {h: 0 for h in Health}
    for h, _ in classified:
        counts[h] += 1
    summary = "  ".join(
        f"[{_HEALTH_STYLE[h]}]{counts[h]} {h.value}[/{_HEALTH_STYLE[h]}]"
        for h in (Health.FAILED, Health.ESCALATED, Health.ATTENTION,
                  Health.INFO, Health.HEALTHY)
        if counts[h] or filter_levels is None or h in filter_levels
    )
    yield Panel(summary, title="lauschi-catalog log-summary", border_style="dim")

    table = Table(box=box.SIMPLE_HEAD, show_lines=False)
    table.add_column("series_id", style="bold")
    table.add_column("health", justify="center")
    table.add_column("curate", justify="center")
    table.add_column("review", justify="center")
    table.add_column("verify", justify="center")
    table.add_column("flags")

    for health, r in classified:
        style = _HEALTH_STYLE[health]
        table.add_row(
            r.series_id,
            f"[{style}]{health.value}[/{style}]",
            _phase_cell(r.curate_status),
            _phase_cell(r.review_status),
            _phase_cell(r.verify_status),
            " ".join(collect_flags(r)) or "[dim]—[/dim]",
        )
    yield table


def render_detail(r: SeriesReport) -> Panel:
    """Verbose per-series breakdown showing every captured signal."""
    health = classify(r)
    style = _HEALTH_STYLE[health]
    lines = [
        f"[bold]{r.series_id}[/bold]" + (f"  [dim]{r.title}[/dim]" if r.title else ""),
        f"health: [{style}]{health.value}[/{style}]",
        "",
        "[bold]Curate[/bold]",
        f"  status:   {r.curate_status}",
    ]
    if r.flow:
        lines.append(f"  flow:     {r.flow} ({r.total_albums} albums)")
    if r.curate_status == "failed":
        lines.append(f"  failure:  [red]{r.curate_failure_kind}[/red]")
        if r.curate_failure_detail:
            lines.append(f"  detail:   [dim]{r.curate_failure_detail[:300]}[/dim]")
    if r.id_lock_fired:
        lines.append(f"  id-lock:  '{r.id_lock_from}' → '{r.series_id}'")
    if r.search_disambiguation:
        lines.append(f"  disambig: chose primary; also matched {r.search_disambiguation_alt}")
    if r.pattern_coverage_warning:
        lines.append(
            f"  coverage: [yellow]{r.pattern_coverage_matched}/"
            f"{r.pattern_coverage_total}[/yellow] (low — agent should have refined)"
        )
    if r.pattern_revised_mid_run:
        lines.append(
            f"  revised:  {r.pattern_initial} → {r.pattern_final} "
            f"([cyan]+{r.pattern_re_extracted}[/cyan] re-extracted)"
        )

    lines.append("")
    lines.append("[bold]Review[/bold]")
    lines.append(f"  status:   {r.review_status}")
    if r.review_status == "success":
        lines.append(
            f"  actions:  {r.review_overrides} overrides, "
            f"{r.review_splits} splits, {r.review_added} added"
            + (", pattern_update" if r.review_pattern_update else "")
        )
        if r.review_verdicts:
            verdicts = "  | ".join(
                f"{c}:{r.review_verdicts.get(c, '?')}"
                for c in _VERDICT_CATEGORIES
            )
            lines.append(f"  verdicts: {verdicts}")
        if r.review_deferred_categories:
            lines.append(
                f"  deferred: [yellow]{', '.join(r.review_deferred_categories)}[/yellow]"
            )
        if r.review_coerced_categories:
            lines.append(
                f"  coerced:  [yellow]{', '.join(set(r.review_coerced_categories))}[/yellow]"
            )
        if r.review_summary:
            lines.append(f"  summary:  [dim]{r.review_summary[:300]}[/dim]")

    lines.append("")
    lines.append("[bold]Verify[/bold]")
    lines.append(f"  status:   {r.verify_status}")
    if r.verify_concerns:
        lines.append(f"  concerns: [dim]{r.verify_concerns[:300]}[/dim]")

    return Panel("\n".join(lines), border_style=style)


def render_ids(
    reports: dict[str, SeriesReport],
    *,
    filter_levels: set[Health],
) -> str:
    """Bare list of series_ids matching the filter, one per line."""
    matched = sorted(
        r.series_id for r in reports.values()
        if classify(r) in filter_levels
    )
    return "\n".join(matched)


def render_json(reports: dict[str, SeriesReport]) -> str:
    """Full structured output."""
    out = {}
    for sid, r in sorted(reports.items()):
        d = dict(r.__dict__)
        d["health"] = classify(r).value
        d["flags"] = collect_flags(r)
        out[sid] = d
    return json.dumps(out, indent=2, ensure_ascii=False, sort_keys=False)


# ── CLI ───────────────────────────────────────────────────────────────────


def _resolve_log_path(arg: str | None) -> Path:
    """Resolve the log argument to a concrete file path.

    With no arg, picks the most recent ``logs/catalog/pipeline-*.log``.

    Relative paths are tried first against cwd, then against
    REPO_ROOT. The mise task runs `uv run --directory tools …`, so
    cwd is `tools/` and a path like `logs/catalog/foo.log` (the form
    the pipeline scripts print) would otherwise miss. Falling back to
    REPO_ROOT makes the user-facing relative path work uniformly.
    """
    if arg:
        p = Path(arg)
        if p.is_absolute():
            if not p.exists():
                raise click.BadParameter(f"log path does not exist: {p}")
            return p
        for candidate in (p, REPO_ROOT / p):
            if candidate.exists():
                return candidate
        raise click.BadParameter(f"log path does not exist: {p}")
    candidates = sorted(LOG_DIR.glob("pipeline-*.log"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise click.BadParameter(
            f"no pipeline logs found in {LOG_DIR}; pass an explicit path",
        )
    return candidates[-1]


_FILTER_CHOICES = [h.value for h in Health] + ["all", "default"]
_DEFAULT_FILTER = {Health.FAILED, Health.ESCALATED, Health.ATTENTION}


def _parse_filter(value: str) -> set[Health]:
    if value in ("", "default"):
        return set(_DEFAULT_FILTER)
    if value == "all":
        return set(Health)
    chosen: set[Health] = set()
    for part in value.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            chosen.add(Health(part))
        except ValueError as e:
            raise click.BadParameter(
                f"invalid health level {part!r}; "
                f"pick from {', '.join(_FILTER_CHOICES)}",
            ) from e
    return chosen or set(_DEFAULT_FILTER)


@click.command("log-summary")
@click.argument("log", required=False)
@click.option(
    "--filter", "filter_str", default="default",
    help=(
        "Comma-separated health levels to include. "
        "Default: failed,escalated,attention. Special: 'all'."
    ),
)
@click.option(
    "--ids", "as_ids", is_flag=True,
    help="Output just the series_ids (one per line). Suitable for piping.",
)
@click.option("--as-json", "as_json", is_flag=True, help="Output structured JSON.")
@click.option(
    "--detail", "detail_id", default=None,
    help="Show every captured signal for one series_id.",
)
def log_summary(
    log: str | None,
    filter_str: str,
    as_ids: bool,
    as_json: bool,
    detail_id: str | None,
) -> None:
    """Per-series re-run report from a catalog-pipeline log.

    Without arguments, mines the latest pipeline log in
    logs/catalog/. Pass a path to inspect a specific run.

    Examples:

      lauschi-catalog log-summary
      lauschi-catalog log-summary logs/catalog/pipeline-X.log --filter failed
      lauschi-catalog log-summary --ids --filter failed | xargs ...
      lauschi-catalog log-summary --detail die_drei_fragezeichen
    """
    path = _resolve_log_path(log)
    reports = parse_log(path)

    if not reports:
        console.print(f"[yellow]No series signals found in {path}[/yellow]")
        return

    if detail_id:
        r = reports.get(detail_id)
        if not r:
            raise click.BadParameter(f"series_id {detail_id!r} not present in this log")
        console.print(render_detail(r))
        return

    levels = _parse_filter(filter_str)

    if as_json:
        # JSON output isn't filtered — that's a separate operation
        # (jq from the result). Always emit everything.
        click.echo(render_json(reports))
        return

    if as_ids:
        click.echo(render_ids(reports, filter_levels=levels))
        return

    console.print(f"[dim]source: {path}  ({len(reports)} series in log)[/dim]")
    state = _scan_pipeline_state(path)
    catalog_size = _catalog_size() or None
    console.print(render_progress(reports, state, catalog_size=catalog_size))
    for renderable in render_pretty(reports, filter_levels=levels):
        console.print(renderable)
