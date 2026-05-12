"""Tests for the log-summary parser.

The parser is the load-bearing piece of this command — if it
misattributes signals, every report it surfaces is wrong. These
tests use small synthetic log fixtures that mimic real pipeline
output so that future refactors of the agents' log lines don't
silently break attribution.

Each fixture is a verbatim slice of the format the agents produce
(curate header, review verdicts post-Save, verify approve, etc.).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from lauschi_catalog.commands.log_summary import (
    REPO_ROOT,
    Health,
    _resolve_log_path,
    classify,
    collect_flags,
    parse_log,
)


@pytest.fixture
def tmp_log(tmp_path: Path):
    """Helper to write a log fixture and return its path."""
    def _write(text: str) -> Path:
        p = tmp_path / "pipeline.log"
        p.write_text(text)
        return p
    return _write


# ── curate phase ──────────────────────────────────────────────────────────


def test_parses_successful_curate_with_save(tmp_log):
    """Happy path: header, flow, save → curate_status=success."""
    log = tmp_log(
        "Step 1/5: Curating all series (this takes hours)...\n"
        "(1/171) Yakari (0 done, 0 failed, 0 skipped)\n"
        "  77 albums — using single-agent flow\n"
        "Saved to /repo/assets/catalog/curation/yakari.json\n"
    )
    reports = parse_log(log)
    r = reports["yakari"]
    assert r.curate_status == "success"
    assert r.flow == "single-agent"
    assert r.total_albums == 77
    assert classify(r) == Health.HEALTHY


def test_parses_curate_failure_http_404(tmp_log):
    log = tmp_log(
        "Step 1/5: Curating all series (this takes hours)...\n"
        "(2/171) Bob der Baumeister (1 done, 0 failed, 0 skipped)\n"
        "Failed to curate Bob der Baumeister: HTTPError: 404 Client Error: "
        "Not Found for url: https://api.music.apple.com/v1/catalog/de/artists/X/albums\n",
    )
    reports = parse_log(log)
    # Title "Bob der Baumeister" → resolved via series.yaml mapping if available,
    # else slugified. Test by looking up the failed entry regardless of key.
    failed = [r for r in reports.values() if r.curate_status == "failed"]
    assert len(failed) == 1
    r = failed[0]
    assert r.curate_failure_kind == "http_404"
    assert "404" in (r.curate_failure_detail or "")
    assert classify(r) == Health.FAILED


def test_parses_curate_failure_timeout(tmp_log):
    log = tmp_log(
        "(3/171) Nils Holgersson (2 done, 1 failed, 0 skipped)\n"
        "Failed to curate Nils Holgersson: TimeoutError\n",
    )
    reports = parse_log(log)
    failed = next(iter(reports.values()))
    assert failed.curate_failure_kind == "timeout"


def test_parses_id_lock_event(tmp_log):
    """The lock-helper firing is benign info, not a failure."""
    log = tmp_log(
        "(1/171) Hui Buh das Schlossgespenst (0 done, 0 failed, 0 skipped)\n"
        "  46 albums — using single-agent flow\n"
        "  Locked id to canonical: 'hui_buh_das_schlossgespenst' → 'hui_buh' "
        "(model output overridden by series.yaml)\n"
        "Saved to /repo/assets/catalog/curation/hui_buh.json\n",
    )
    reports = parse_log(log)
    r = reports["hui_buh"]
    assert r.id_lock_fired is True
    assert r.id_lock_from == "hui_buh_das_schlossgespenst"
    assert classify(r) == Health.INFO
    assert any("id-locked" in f for f in collect_flags(r))


def test_parses_pattern_coverage_warning(tmp_log):
    log = tmp_log(
        "(1/171) Test Series (0 done, 0 failed, 0 skipped)\n"
        "  609 albums — using batched flow\n"
        "  ⚠ Low metadata-phase pattern coverage: 56/305 = 18%. "
        "Batch agent may revise via propose_pattern_update.\n"
        "Saved to /repo/assets/catalog/curation/test_series.json\n",
    )
    reports = parse_log(log)
    r = reports["test_series"]
    assert r.pattern_coverage_warning is True
    assert r.pattern_coverage_matched == 56
    assert r.pattern_coverage_total == 305
    assert classify(r) == Health.ATTENTION


def test_parses_pattern_revision_mid_run(tmp_log):
    log = tmp_log(
        "(1/171) Test (0 done, 0 failed, 0 skipped)\n"
        "  609 albums — using batched flow\n"
        "  Pattern revised mid-run: '^Folge (\\d+):' → "
        "['^Folge (\\d+):', '^(\\d+)/']. Re-extracted 184 episode numbers.\n"
        "Saved to /repo/assets/catalog/curation/test.json\n",
    )
    reports = parse_log(log)
    r = reports["test"]
    assert r.pattern_revised_mid_run is True
    assert r.pattern_re_extracted == 184
    assert classify(r) == Health.ATTENTION


# ── review phase ──────────────────────────────────────────────────────────


def test_parses_review_verdicts_after_save(tmp_log):
    """Critical case: verdicts arrive AFTER the Save line in review's
    output. Parser must keep the active record bound to the just-saved
    series so verdicts/summary/coercion attribute correctly."""
    log = tmp_log(
        "Step 2/5: AI review...\n"
        "Reviewing Bibi Blocksberg...\n"
        "⚠ Coerced inconsistent verdicts to deferred_to_human: gaps\n"
        "  6 overrides, 0 splits, 0 added\n"
        "  Saved to /repo/assets/catalog/curation/bibi_blocksberg.json\n"
        "    dup:resolved_via_overrides | sub:no_sub_series_mixed_in | "
        "gap:deferred_to_human | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:verified_content_rotation\n"
        "  Summary: Bibi Blocksberg curation had 5 episodes restored.\n",
    )
    reports = parse_log(log)
    r = reports["bibi_blocksberg"]
    assert r.review_status == "success"
    assert r.review_overrides == 6
    assert r.review_verdicts["duplicates"] == "resolved_via_overrides"
    assert r.review_verdicts["gaps"] == "deferred_to_human"
    assert r.review_deferred_categories == ["gaps"]
    assert r.review_coerced_categories == ["gaps"]
    assert "5 episodes restored" in r.review_summary
    assert classify(r) == Health.ATTENTION


def test_parses_review_removal_proposal(tmp_log):
    """propose_removal is the agent's "this entry is bullshit"
    verdict. The reason gets logged as a "🗑️ Removal proposed:"
    one-liner; the counts line gets ", removal_proposed" appended.
    Both signals must surface in the parser; classify must promote
    the report to ATTENTION so the human sees it in the default
    filter."""
    log = tmp_log(
        "Step 2/5: AI review...\n"
        "Reviewing Tom Turbo...\n"
        "  0 overrides, 0 splits, 0 added, removal_proposed\n"
        "  🗑️ Removal proposed: No streaming presence on Spotify or Apple Music; only Audible.\n"
        "  Saved to /repo/assets/catalog/curation/tom_turbo.json\n"
        "    dup:no_within_provider_duplicates | sub:no_sub_series_mixed_in | "
        "gap:no_gaps_present | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:balanced\n"
        "  Summary: Tom Turbo is only on Audible.\n",
    )
    reports = parse_log(log)
    r = reports["tom_turbo"]
    assert r.review_status == "success"
    assert r.review_removal_proposed is True
    assert "No streaming presence" in r.review_removal_reason
    assert classify(r) == Health.ATTENTION
    assert "🗑️removal-proposed" in collect_flags(r)


def test_review_counts_line_alone_surfaces_removal_flag(tmp_log):
    """The counts line ", removal_proposed" suffix alone is enough
    to know the agent proposed removal — even without parsing the
    🗑️ reason line. Pin this so a log captured mid-stream still
    classifies correctly."""
    log = tmp_log(
        "Step 2/5: AI review...\n"
        "Reviewing Tom Turbo...\n"
        "  0 overrides, 0 splits, 0 added, pattern_update, removal_proposed\n"
        "  Saved to /repo/assets/catalog/curation/tom_turbo.json\n",
    )
    reports = parse_log(log)
    r = reports["tom_turbo"]
    assert r.review_pattern_update is True
    assert r.review_removal_proposed is True


def test_parses_review_skip(tmp_log):
    log = tmp_log(
        "Step 2/5: AI review...\n"
        "Skipping yakari (already approved; use --force to re-review)\n",
    )
    reports = parse_log(log)
    r = reports["yakari"]
    assert r.review_status == "skipped"


def test_review_with_multiple_deferred_categories(tmp_log):
    log = tmp_log(
        "Reviewing Test...\n"
        "  0 overrides, 0 splits, 0 added\n"
        "  Saved to /repo/assets/catalog/curation/test.json\n"
        "    dup:deferred_to_human | sub:deferred_to_human | "
        "gap:no_gaps_present | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:balanced\n",
    )
    reports = parse_log(log)
    r = reports["test"]
    assert set(r.review_deferred_categories) == {"duplicates", "sub_series"}
    assert classify(r) == Health.ATTENTION


def test_review_pattern_update_flag(tmp_log):
    log = tmp_log(
        "Reviewing Test...\n"
        "  3 overrides, 0 splits, 0 added, pattern_update\n"
        "  Saved to /repo/assets/catalog/curation/test.json\n",
    )
    reports = parse_log(log)
    r = reports["test"]
    assert r.review_pattern_update is True


# ── verify phase ──────────────────────────────────────────────────────────


def test_parses_verify_approved(tmp_log):
    log = tmp_log(
        "Step 3/5: 4-eye verification...\n"
        "Verifying yakari...\n"
        "  ✓ Approved\n",
    )
    reports = parse_log(log)
    assert reports["yakari"].verify_status == "approved"
    assert classify(reports["yakari"]) == Health.HEALTHY


def test_parses_verify_escalated_with_concerns(tmp_log):
    log = tmp_log(
        "Verifying tkkg...\n"
        "  ⚠ Escalated for human review\n"
        "  Concerns: Episode 100 is on Spotify but episode list shows it as a "
        "compilation, not a standalone Hörspiel.\n",
    )
    reports = parse_log(log)
    r = reports["tkkg"]
    assert r.verify_status == "escalated"
    assert "Episode 100" in r.verify_concerns
    assert classify(r) == Health.ESCALATED


# ── multi-phase end-to-end ────────────────────────────────────────────────


def test_full_pipeline_for_one_series(tmp_log):
    """Curate, review, verify all attribute to the same SeriesReport."""
    log = tmp_log(
        "Step 1/5: Curating...\n"
        "(1/171) Yakari (0 done, 0 failed, 0 skipped)\n"
        "  77 albums — using single-agent flow\n"
        "Saved to /repo/assets/catalog/curation/yakari.json\n"
        "Step 2/5: AI review...\n"
        "Reviewing Yakari...\n"
        "  0 overrides, 0 splits, 0 added\n"
        "  Saved to /repo/assets/catalog/curation/yakari.json\n"
        "    dup:no_within_provider_duplicates | sub:no_sub_series_mixed_in | "
        "gap:no_gaps_present | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:balanced\n"
        "  Summary: All clean.\n"
        "Step 3/5: Verify...\n"
        "Verifying yakari...\n"
        "  ✓ Approved\n",
    )
    reports = parse_log(log)
    assert len(reports) == 1
    r = reports["yakari"]
    assert r.curate_status == "success"
    assert r.review_status == "success"
    assert r.verify_status == "approved"
    assert classify(r) == Health.HEALTHY


def test_same_title_different_subseries_resolved_by_save(tmp_log):
    """Bibi Blocksberg + Bibi Blocksberg-Kinofilme share a title but
    save to different ids. The save line is the disambiguator —
    each Reviewing/Save pair must attribute to its own series."""
    log = tmp_log(
        "Reviewing Bibi Blocksberg...\n"
        "  6 overrides, 0 splits, 0 added\n"
        "  Saved to /repo/assets/catalog/curation/bibi_blocksberg.json\n"
        "    dup:resolved_via_overrides | sub:no_sub_series_mixed_in | "
        "gap:no_gaps_present | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:balanced\n"
        "Reviewing Bibi Blocksberg...\n"
        "  0 overrides, 0 splits, 0 added\n"
        "  Saved to /repo/assets/catalog/curation/bibi_blocksberg_kinofilme.json\n"
        "    dup:no_within_provider_duplicates | sub:splits_proposed | "
        "gap:no_gaps_present | pat:current_pattern_correct | "
        "out:no_outliers_found | xprov:single_provider_only\n",
    )
    reports = parse_log(log)
    assert "bibi_blocksberg" in reports
    assert "bibi_blocksberg_kinofilme" in reports
    assert reports["bibi_blocksberg"].review_overrides == 6
    assert reports["bibi_blocksberg_kinofilme"].review_overrides == 0
    assert reports["bibi_blocksberg_kinofilme"].review_verdicts["sub_series"] == "splits_proposed"


# ── classification ────────────────────────────────────────────────────────


def test_classification_failed_beats_everything():
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(series_id="x", curate_status="failed", verify_status="approved")
    r.review_deferred_categories = ["gaps"]
    assert classify(r) == Health.FAILED


def test_classification_escalated_beats_attention():
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(series_id="x", verify_status="escalated")
    r.review_deferred_categories = ["gaps"]
    assert classify(r) == Health.ESCALATED


def test_classification_attention_for_low_coverage():
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(
        series_id="x", pattern_coverage_warning=True,
        pattern_coverage_matched=40, pattern_coverage_total=300,
    )
    assert classify(r) == Health.ATTENTION


def test_classification_info_for_id_lock_only():
    """ID lock fires routinely; should be info, not attention."""
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(series_id="x", id_lock_fired=True, curate_status="success")
    assert classify(r) == Health.INFO


def test_classification_healthy_when_nothing_flagged():
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(series_id="x", curate_status="success", review_status="success")
    assert classify(r) == Health.HEALTHY


# ── flags ─────────────────────────────────────────────────────────────────


def test_flag_collection_for_compound_signals():
    from lauschi_catalog.commands.log_summary import SeriesReport

    r = SeriesReport(
        series_id="x",
        id_lock_fired=True, id_lock_from="oldid",
        pattern_coverage_warning=True,
        pattern_coverage_matched=10, pattern_coverage_total=50,
    )
    r.review_deferred_categories = ["gaps", "outliers"]
    flags = collect_flags(r)
    assert any("id-locked" in f for f in flags)
    assert any("low-coverage:10/50" in f for f in flags)
    assert any("defer:gaps,outliers" in f for f in flags)


# ── empty / malformed input ───────────────────────────────────────────────


def test_empty_log(tmp_log):
    reports = parse_log(tmp_log(""))
    assert reports == {}


def test_log_with_no_pipeline_signals(tmp_log):
    reports = parse_log(tmp_log("Some random text\nNothing matches\n"))
    assert reports == {}


# ── _resolve_log_path: cwd-vs-repo-root resolution ────────────────────────
#
# The mise catalog-log-summary task runs `uv run --directory tools …`
# which chdirs into tools/. The pipeline scripts log paths like
# `logs/catalog/pipeline-foo.log` (relative to repo root). Without
# fallback resolution, that path misses from tools/ and the user
# sees "log path does not exist" even when the file is right there.


def test_resolve_log_path_falls_back_to_repo_root(tmp_path, monkeypatch):
    """A relative path that doesn't exist in cwd but does at
    REPO_ROOT must resolve. Simulates the mise task running from
    tools/ with a path like `logs/catalog/foo.log`."""
    log_dir = REPO_ROOT / "logs" / "catalog"
    log_dir.mkdir(parents=True, exist_ok=True)
    real = log_dir / "_resolve_test.log"
    real.write_text("x")
    try:
        # Pretend we're running from a directory where the relative
        # path doesn't resolve directly.
        monkeypatch.chdir(tmp_path)
        resolved = _resolve_log_path("logs/catalog/_resolve_test.log")
        assert resolved == real
    finally:
        real.unlink(missing_ok=True)


def test_resolve_log_path_prefers_cwd_when_both_exist(tmp_path, monkeypatch):
    """When the relative path resolves both at cwd and at REPO_ROOT,
    cwd wins. Keeps the natural user expectation when they're at
    repo root and pass a relative path."""
    cwd_file = tmp_path / "test.log"
    cwd_file.write_text("cwd")
    monkeypatch.chdir(tmp_path)
    resolved = _resolve_log_path("test.log")
    assert resolved.read_text() == "cwd"


def test_resolve_log_path_absolute_path_used_as_is(tmp_path):
    real = tmp_path / "absolute.log"
    real.write_text("y")
    resolved = _resolve_log_path(str(real))
    assert resolved == real


def test_resolve_log_path_missing_raises(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    import click
    with pytest.raises(click.BadParameter):
        _resolve_log_path("nope/never/exists.log")
