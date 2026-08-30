"""One JSON line per series per pipeline phase, for machines to read.

Curate, audit, and validate append an event per series; the web UI and
future tooling read those lines instead of parsing human console logs.
Files land in logs/catalog/run-<start-stamp>.jsonl, one file per
process run.
"""

import json
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from filelock import FileLock

from lauschi_catalog.catalog.paths import log_dir

#: Outcome values, so the golden test can pin what the emitter writes.
OUTCOME_OK = "ok"
OUTCOME_FAILED = "failed"
OUTCOME_SKIPPED = "skipped"

_process_stamp: str | None = None


@dataclass
class RunEvent:
    series_id: str
    phase: str  # curate | audit | apply | validate | ...
    outcome: str  # ok | failed | skipped
    detail: str = ""
    usage: dict[str, int] = field(default_factory=dict)
    evidence: str | None = None
    recorded_at: str = ""

    def __post_init__(self) -> None:
        if not self.recorded_at:
            self.recorded_at = datetime.now(UTC).isoformat(timespec="seconds")


def _start_stamp() -> str:
    """File stamp for this process run, fixed on first use."""
    global _process_stamp
    if _process_stamp is None:
        _process_stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
    return _process_stamp


def run_events_path(base: Path | None = None) -> Path:
    return (base or log_dir()) / f"run-{_start_stamp()}.jsonl"


def record_event(event: RunEvent, *, base: Path | None = None) -> Path:
    """Append one event as a JSON line. Returns the file written."""
    path = run_events_path(base)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(asdict(event), ensure_ascii=False)
    with FileLock(str(path) + ".lock"):
        with path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    return path


def read_events(base: Path | None = None) -> list[RunEvent]:
    """All recorded events across run files, oldest run first.

    Corrupt or partial lines (a killed process mid-write) are skipped;
    an event log is diagnostic, and one bad line must not take the web
    UI down.
    """
    directory = base or log_dir()
    if not directory.exists():
        return []
    events: list[RunEvent] = []
    for path in sorted(directory.glob("run-*.jsonl")):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                data = json.loads(line)
                events.append(RunEvent(**data))
            except json.JSONDecodeError, TypeError, ValueError:
                continue
    return events


def latest_outcome_for(
    series_id: str, phase: str, base: Path | None = None
) -> str | None:
    """The most recent outcome recorded for a series+phase, if any."""
    found: str | None = None
    for event in read_events(base):
        if event.series_id == series_id and event.phase == phase:
            found = event.outcome
    return found
