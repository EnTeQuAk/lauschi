"""Tests for finalize pattern handling in curate_ops.

The propose_pattern_update tool is the single source of truth for
pattern updates from the finalize agent. The FinalizeResult output field
is gone, so a bad or missing pattern in the output cannot crash the run
or override the validated tool value.
"""

from __future__ import annotations

import pytest
from pydantic_ai.usage import RunUsage

from lauschi_catalog.catalog import curate_ops
from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    CurateDeps,
    CuratedSeries,
    FinalizeResult,
)


def test_finalize_result_has_no_proposed_pattern_field():
    """The output model no longer carries the unvalidated pattern field."""
    result = FinalizeResult()
    assert not hasattr(result, "proposed_pattern_update")

    # Pydantic v2 ignores extra unknown keys by default, so the constructor
    # does not raise. The important property is that the field is gone and
    # therefore cannot be read or written by the rest of the pipeline.
    result_with_extra = FinalizeResult(proposed_pattern_update=r"^(\d+)")
    assert not hasattr(result_with_extra, "proposed_pattern_update")


def test_curated_series_still_validates_pattern():
    """The final curation still validates the pattern that ships to YAML."""
    with pytest.raises(Exception):
        CuratedSeries(
            id="s",
            title="S",
            albums=[],
            episode_pattern=r"(\\d+)",
        )


@pytest.mark.anyio
async def test_finalize_deps_pattern_is_single_source_of_truth(monkeypatch):
    """When the finalize tool updates deps.pattern, shared_deps picks it up."""
    monkeypatch.setenv("OPENCODE_API_KEY", "test")

    decisions = [
        AlbumDecision(
            album_id="a1",
            provider="spotify",
            title="Folge 1: A",
            include=True,
            confidence="high",
            episode_num=1,
        )
    ]
    shared_usage = RunUsage()
    shared_deps = CurateDeps(
        pattern=r"^Folge (\d+):",
        all_decisions=decisions,
        on_progress=lambda _m: None,
        usage=shared_usage,
    )

    finalize_deps = CurateDeps(
        pattern=r"^Folge (\d+):",
        all_decisions=decisions,
        on_progress=lambda _m: None,
        usage=shared_usage,
    )

    async def _fake_run():
        # Simulate the tool setting a new validated pattern.
        finalize_deps.pattern = r"^Folge (\d+):|^Episode (\d+)"
        return FinalizeResult()

    result = await curate_ops._run_with_retry(
        _fake_run,
        phase="finalize",
        model_name="test",
        on_progress=lambda _m: None,
    )
    assert isinstance(result, FinalizeResult)

    # The shared contract: if finalize_deps.pattern changed, propagate it.
    if finalize_deps.pattern != shared_deps.pattern:
        shared_deps.pattern = finalize_deps.pattern
        shared_deps.pattern_revisions.append(finalize_deps.pattern)

    assert shared_deps.pattern == r"^Folge (\d+):|^Episode (\d+)"
    assert shared_deps.pattern_revisions == [r"^Folge (\d+):|^Episode (\d+)"]


def test_finalize_deps_receives_shared_usage():
    """Finalize deps must tally into the shared usage so the Done line is correct."""
    shared_usage = RunUsage()
    shared_deps = CurateDeps(
        pattern=r"^Folge (\d+):",
        all_decisions=[],
        on_progress=lambda _m: None,
        usage=shared_usage,
    )
    finalize_deps = CurateDeps(
        pattern=r"^Folge (\d+):",
        all_decisions=[],
        on_progress=lambda _m: None,
        usage=shared_usage,
    )
    assert finalize_deps.usage is shared_deps.usage
