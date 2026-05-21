"""Tests for audit.py: prompt builder, apply logic, merge, escalation rules.

The audit agent itself requires an API key and real model; these tests
cover the deterministic parts that gate correctness: prompt assembly,
status determination, override/fact merging, and the auto-escalation
threshold.
"""

from __future__ import annotations

import json

import pytest
import ruamel.yaml

from lauschi_catalog.commands.audit import (
    AuditFactUpdate,
    AuditOverride,
    AuditResult,
    _build_prompt,
    _merge_facts,
    apply_audit,
)
from lauschi_catalog.catalog.facts import EraBoundaryProposal, KnownGapProposal


# ── Fixtures ─────────────────────────────────────────────────────────────


def _curation(**overrides) -> dict:
    """Minimal valid curation dict."""
    base = {
        "id": "test_series",
        "title": "Test Series",
        "episode_pattern": r"^Folge (\d+):",
        "albums": [
            {
                "album_id": "a1",
                "provider": "spotify",
                "include": True,
                "episode_num": 1,
                "title": "Folge 1: Test",
                "confidence": "high",
            },
            {
                "album_id": "a2",
                "provider": "spotify",
                "include": False,
                "episode_num": None,
                "title": "Best Of",
                "exclude_reason": "compilation",
            },
        ],
    }
    base.update(overrides)
    return base


# ── _build_prompt ────────────────────────────────────────────────────────


class TestBuildPrompt:
    def test_includes_series_title_and_id(self):
        prompt = _build_prompt(_curation(), [])
        assert "Test Series" in prompt
        assert "test_series" in prompt

    def test_includes_episode_pattern(self):
        prompt = _build_prompt(_curation(), [])
        assert "Folge" in prompt

    def test_separates_included_and_excluded(self):
        prompt = _build_prompt(_curation(), [])
        assert "Included albums (1)" in prompt
        assert "Excluded albums (1)" in prompt

    def test_shows_episode_number_for_included(self):
        prompt = _build_prompt(_curation(), [])
        assert "Ep 1:" in prompt

    def test_shows_exclude_reason(self):
        prompt = _build_prompt(_curation(), [])
        assert "compilation" in prompt

    def test_shows_confidence_tag_for_non_high(self):
        c = _curation()
        c["albums"][0]["confidence"] = "medium"
        prompt = _build_prompt(c, [])
        assert "[medium]" in prompt

    def test_hides_confidence_tag_for_high(self):
        prompt = _build_prompt(_curation(), [])
        assert "[high]" not in prompt

    def test_shows_lint_issues(self):
        prompt = _build_prompt(_curation(), ["Duplicate ep 5 on spotify"])
        assert "Lint findings (1)" in prompt
        assert "Duplicate ep 5" in prompt

    def test_shows_series_facts(self):
        c = _curation(series_facts={
            "era_boundaries": [
                {"label": "klassik", "release_date_range": "1976-1979"},
            ],
            "known_gaps": [
                {"number": 13, "reason": "legal dispute"},
            ],
        })
        prompt = _build_prompt(c, [])
        assert "klassik" in prompt
        assert "1976-1979" in prompt
        assert "episode 13" in prompt
        assert "legal dispute" in prompt

    def test_marks_unaudited_facts(self):
        c = _curation(series_facts={
            "era_boundaries": [
                {"label": "modern", "release_date_range": "2020-"},
            ],
        })
        prompt = _build_prompt(c, [])
        assert "[unaudited]" in prompt

    def test_marks_audited_facts(self):
        c = _curation(series_facts={
            "era_boundaries": [
                {
                    "label": "modern",
                    "release_date_range": "2020-",
                    "audited_by": "minimax",
                },
            ],
        })
        prompt = _build_prompt(c, [])
        assert "[audited by minimax]" in prompt

    def test_shows_all_excluded(self):
        albums = [
            {
                "album_id": f"x{i}",
                "provider": "spotify",
                "include": False,
                "title": f"Excluded {i}",
                "exclude_reason": "compilation",
            }
            for i in range(50)
        ]
        c = _curation(albums=albums)
        prompt = _build_prompt(c, [])
        assert prompt.count("[spotify] Excluded ") == 50

    def test_shows_all_lint_issues(self):
        issues = [f"Issue {i}" for i in range(30)]
        prompt = _build_prompt(_curation(), issues)
        assert "Lint findings (30)" in prompt
        assert prompt.count("Issue ") == 30


# ── apply_audit: status determination ────────────────────────────────────


class TestApplyAuditStatus:
    def _apply(self, tmp_path, result: AuditResult) -> str:
        path = tmp_path / "test_series.json"
        path.write_text(json.dumps(_curation()))

        import lauschi_catalog.commands.audit as audit_mod
        orig = audit_mod.CURATION_DIR
        audit_mod.CURATION_DIR = tmp_path
        try:
            action = apply_audit(
                "test_series", result, model_name="test-model",
            )
        finally:
            audit_mod.CURATION_DIR = orig
        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        return action, data

    def test_clean_approval(self, tmp_path):
        result = AuditResult(approve=True)
        action, data = self._apply(tmp_path, result)
        assert action == "approved"
        assert data["review"]["status"] == "approved"

    def test_approval_with_overrides_is_overridden(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="a2", provider="spotify",
                    action="include", reason="real episode",
                ),
            ],
        )
        action, data = self._apply(tmp_path, result)
        assert action == "overridden"
        assert data["review"]["status"] == "approved"

    def test_approval_with_fact_updates_is_overridden(self, tmp_path):
        result = AuditResult(
            approve=True,
            fact_updates=[AuditFactUpdate()],
        )
        action, data = self._apply(tmp_path, result)
        assert action == "overridden"

    def test_disapproval_escalates(self, tmp_path):
        result = AuditResult(approve=False, concerns=["big problem"])
        action, data = self._apply(tmp_path, result)
        assert action == "escalated"
        assert data["review"]["status"] == "escalated"

    def test_more_than_5_concerns_auto_escalates(self, tmp_path):
        result = AuditResult(
            approve=True,
            concerns=[f"concern {i}" for i in range(6)],
        )
        action, data = self._apply(tmp_path, result)
        assert action == "escalated"
        assert data["review"]["status"] == "escalated"

    def test_exactly_5_concerns_does_not_escalate(self, tmp_path):
        result = AuditResult(
            approve=True,
            concerns=[f"concern {i}" for i in range(5)],
        )
        action, data = self._apply(tmp_path, result)
        assert action == "approved"

    def test_stamps_audited_by_and_at(self, tmp_path):
        result = AuditResult(approve=True)
        _, data = self._apply(tmp_path, result)
        assert data["review"]["audited_by"] == "test-model"
        assert data["review"]["audited_at"]

    def test_persists_concerns(self, tmp_path):
        result = AuditResult(
            approve=True,
            concerns=["minor issue"],
        )
        _, data = self._apply(tmp_path, result)
        assert data["review"]["concerns"] == ["minor issue"]


# ── apply_audit: override merging ────────────────────────────────────────


class TestApplyAuditOverrides:
    def test_override_stamps_audited_by(self, tmp_path):
        path = tmp_path / "test_series.json"
        path.write_text(json.dumps(_curation()))

        import lauschi_catalog.commands.audit as audit_mod
        orig = audit_mod.CURATION_DIR
        audit_mod.CURATION_DIR = tmp_path
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2", provider="spotify",
                        action="include", reason="real episode",
                    ),
                ],
            )
            apply_audit("test_series", result, model_name="test-model")
        finally:
            audit_mod.CURATION_DIR = orig

        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        overrides = data["review"]["overrides"]
        assert len(overrides) == 1
        assert overrides[0]["audited_by"] == "test-model"
        assert overrides[0]["action"] == "include"

    def test_override_merges_with_existing(self, tmp_path):
        c = _curation()
        c["review"] = {
            "overrides": [
                {
                    "album_id": "old_album",
                    "provider": "spotify",
                    "action": "exclude",
                    "reason": "old reason",
                    "audited_by": "old-model",
                    "audited_at": "2026-01-01T00:00:00+00:00",
                },
            ],
        }
        path = tmp_path / "test_series.json"
        path.write_text(json.dumps(c))

        import lauschi_catalog.commands.audit as audit_mod
        orig = audit_mod.CURATION_DIR
        audit_mod.CURATION_DIR = tmp_path
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2", provider="spotify",
                        action="include", reason="new override",
                    ),
                ],
            )
            apply_audit("test_series", result, model_name="test-model")
        finally:
            audit_mod.CURATION_DIR = orig

        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        overrides = {o["album_id"]: o for o in data["review"]["overrides"]}
        assert "old_album" in overrides
        assert "a2" in overrides
        assert overrides["a2"]["reason"] == "new override"


# ── _merge_facts ─────────────────────────────────────────────────────────


class TestMergeFacts:
    def test_adds_new_era_boundary(self):
        series_facts: dict = {"era_boundaries": []}
        update = AuditFactUpdate(
            era_boundaries=[EraBoundaryProposal(label="klassik", release_date_range="1976-1979")],
        )
        _merge_facts(series_facts, update, "test-model", "2026-01-01T00:00:00+00:00")
        assert len(series_facts["era_boundaries"]) == 1
        assert series_facts["era_boundaries"][0]["label"] == "klassik"
        assert series_facts["era_boundaries"][0]["audited_by"] == "test-model"

    def test_updates_existing_era_boundary_by_label(self):
        series_facts: dict = {
            "era_boundaries": [
                {"label": "klassik", "release_date_range": "1976-1980", "curated_by": "curate"},
            ],
        }
        update = AuditFactUpdate(
            era_boundaries=[EraBoundaryProposal(label="klassik", release_date_range="1976-1979")],
        )
        _merge_facts(series_facts, update, "test-model", "2026-01-01T00:00:00+00:00")
        assert len(series_facts["era_boundaries"]) == 1
        assert series_facts["era_boundaries"][0]["release_date_range"] == "1976-1979"
        assert series_facts["era_boundaries"][0]["audited_by"] == "test-model"

    def test_adds_new_known_gap(self):
        series_facts: dict = {"known_gaps": []}
        update = AuditFactUpdate(
            known_gaps=[KnownGapProposal(number=13, reason="legal dispute")],
        )
        _merge_facts(series_facts, update, "test-model", "2026-01-01T00:00:00+00:00")
        assert len(series_facts["known_gaps"]) == 1
        assert series_facts["known_gaps"][0]["number"] == 13

    def test_merge_preserves_unmentioned_facts(self):
        series_facts: dict = {
            "era_boundaries": [
                {"label": "klassik", "release_date_range": "1976-1979", "curated_by": "curate"},
            ],
            "known_gaps": [
                {"number": 13, "reason": "old reason", "curated_by": "curate"},
            ],
            "sub_series": [],
        }
        update = AuditFactUpdate(
            era_boundaries=[EraBoundaryProposal(label="modern", release_date_range="2020-")],
        )
        _merge_facts(series_facts, update, "test-model", "2026-01-01T00:00:00+00:00")
        assert len(series_facts["era_boundaries"]) == 2
        assert len(series_facts["known_gaps"]) == 1

    def test_empty_update_is_noop(self):
        series_facts: dict = {
            "era_boundaries": [{"label": "x", "release_date_range": "2020-"}],
            "known_gaps": [],
            "sub_series": [],
        }
        update = AuditFactUpdate()
        _merge_facts(series_facts, update, "test-model", "2026-01-01T00:00:00+00:00")
        assert len(series_facts["era_boundaries"]) == 1


# ── Dry-run mode ─────────────────────────────────────────────────────────


class TestDryRun:
    def test_dry_run_does_not_write(self, tmp_path):
        path = tmp_path / "test_series.json"
        original = _curation()
        path.write_text(json.dumps(original))

        import lauschi_catalog.commands.audit as audit_mod
        orig = audit_mod.CURATION_DIR
        audit_mod.CURATION_DIR = tmp_path
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2", provider="spotify",
                        action="include", reason="test",
                    ),
                ],
            )
            apply_audit(
                "test_series", result, model_name="test-model", dry_run=True,
            )
        finally:
            audit_mod.CURATION_DIR = orig

        data = json.loads(path.read_text())
        assert "review" not in data
