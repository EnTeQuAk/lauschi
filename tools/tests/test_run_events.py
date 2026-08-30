"""Golden tests for the JSONL run-event log.

The web pipeline reads these events instead of parsing console logs,
so the on-disk shape is a contract: fields, outcome values, and the
one-JSON-object-per-line format cannot change without updating this
test and the reader together.
"""

import json
from dataclasses import asdict
from pathlib import Path

import pytest

from lauschi_catalog import run_events as re_mod
from lauschi_catalog.run_events import (
    OUTCOME_FAILED,
    OUTCOME_OK,
    OUTCOME_SKIPPED,
    RunEvent,
    latest_outcome_for,
    read_events,
    record_event,
)


@pytest.fixture
def events_dir(tmp_path: Path) -> Path:
    d = tmp_path / "logs" / "catalog"
    d.mkdir(parents=True)
    return d


def _event(**kw) -> RunEvent:
    base = dict(
        series_id="kira",
        phase="curate",
        outcome=OUTCOME_OK,
        detail="12 included / 2 excluded",
        usage={"requests": 8, "input_tokens": 1200, "output_tokens": 900},
    )
    base.update(kw)
    return RunEvent(**base)


def _write_named(events_dir: Path, name: str, event: RunEvent) -> Path:
    path = events_dir / name
    path.write_text(json.dumps(asdict(event)) + "\n", encoding="utf-8")
    return path


class TestRecordAndRead:
    def test_an_event_round_trips_through_one_json_line(self, events_dir):
        path = record_event(_event(), base=events_dir)

        assert path.parent == events_dir
        assert path.name.startswith("run-")
        assert path.suffix == ".jsonl"

        lines = path.read_text(encoding="utf-8").splitlines()
        assert len(lines) == 1
        data = json.loads(lines[0])
        assert data["series_id"] == "kira"
        assert data["phase"] == "curate"
        assert data["outcome"] == "ok"
        assert data["detail"] == "12 included / 2 excluded"
        assert data["usage"] == {
            "requests": 8,
            "input_tokens": 1200,
            "output_tokens": 900,
        }

    def test_outcome_values_are_the_pinned_vocabulary(self, events_dir):
        for outcome in (OUTCOME_OK, OUTCOME_FAILED, OUTCOME_SKIPPED):
            record_event(_event(outcome=outcome), base=events_dir)
        path = next(events_dir.glob("run-*.jsonl"))
        written = [
            json.loads(line)["outcome"] for line in path.read_text().splitlines()
        ]
        assert written == ["ok", "failed", "skipped"]

    def test_two_events_append_two_lines(self, events_dir):
        record_event(_event(), base=events_dir)
        record_event(_event(series_id="senta"), base=events_dir)
        path = next(events_dir.glob("run-*.jsonl"))
        assert len(path.read_text().strip().splitlines()) == 2

    def test_evidence_path_is_optional_and_kept(self, events_dir):
        record_event(
            _event(
                outcome=OUTCOME_FAILED,
                evidence="logs/catalog/curate-failures/s-batch03.json",
            ),
            base=events_dir,
        )
        (event,) = read_events(events_dir)
        assert event.evidence == "logs/catalog/curate-failures/s-batch03.json"
        assert event.recorded_at  # timestamp set when the emitter writes


class TestRead:
    def test_reads_across_run_files_oldest_first(self, events_dir):
        record_event(_event(detail="first"), base=events_dir)
        _write_named(events_dir, "run-00000000-000000.jsonl", _event(detail="older"))
        events = read_events(events_dir)
        assert [e.detail for e in events] == ["older", "first"]

    def test_partial_and_corrupt_lines_are_skipped(self, events_dir):
        path = events_dir / "run-20260830-120000.jsonl"
        good = json.dumps(asdict(_event()))
        path.write_text(
            good + '\n{"series_id": "half", "phase"\nnot json at all\n',
            encoding="utf-8",
        )
        (event,) = read_events(events_dir)
        assert event.series_id == "kira"

    def test_missing_dir_reads_empty(self, tmp_path):
        assert read_events(tmp_path / "nonexistent") == []


class TestLatestOutcome:
    def test_returns_the_last_recorded_outcome_for_a_phase(self, events_dir):
        record_event(_event(outcome=OUTCOME_FAILED), base=events_dir)
        record_event(_event(outcome=OUTCOME_OK), base=events_dir)
        record_event(_event(phase="audit", outcome=OUTCOME_OK), base=events_dir)
        assert latest_outcome_for("kira", "curate", events_dir) == OUTCOME_OK
        assert latest_outcome_for("kira", "audit", events_dir) == OUTCOME_OK
        assert latest_outcome_for("kira", "validate", events_dir) is None
        assert latest_outcome_for("nobody", "curate", events_dir) is None

    def test_process_stamp_is_stable_within_a_process(self):
        assert re_mod.run_events_path() == re_mod.run_events_path()
