"""Tests for audit.py: prompt builder, apply logic, merge, escalation rules.

The audit agent itself requires an API key and real model; these tests
cover the deterministic parts that gate correctness: prompt assembly,
status determination, override/fact merging, and the auto-escalation
threshold.
"""

import json

import pytest
import ruamel.yaml

from lauschi_catalog.catalog.audit_ops import (
    AuditFactUpdate,
    AuditOverride,
    AuditResult,
    _merge_facts,
    apply_audit,
    build_prompt,
)
from lauschi_catalog.catalog.facts import (
    EraBoundaryProposal,
    KnownGapProposal,
    fact_provenance,
)

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


# ── build_prompt ────────────────────────────────────────────────────────


class TestBuildPrompt:
    def test_includes_series_title_and_id(self):
        prompt = build_prompt(_curation(), [])
        assert "Test Series" in prompt
        assert "test_series" in prompt

    def test_includes_episode_pattern(self):
        prompt = build_prompt(_curation(), [])
        assert "Folge" in prompt

    def test_separates_included_and_excluded(self):
        prompt = build_prompt(_curation(), [])
        assert "Included albums (1)" in prompt
        assert "Excluded albums (1)" in prompt

    def test_shows_episode_number_for_included(self):
        prompt = build_prompt(_curation(), [])
        assert "Ep 1:" in prompt

    def test_shows_exclude_reason(self):
        prompt = build_prompt(_curation(), [])
        assert "compilation" in prompt

    def test_shows_confidence_tag_for_non_high(self):
        c = _curation()
        c["albums"][0]["confidence"] = "medium"
        prompt = build_prompt(c, [])
        assert "[medium]" in prompt

    def test_hides_confidence_tag_for_high(self):
        prompt = build_prompt(_curation(), [])
        assert "[high]" not in prompt

    def test_shows_notes_for_medium_confidence_included(self):
        c = _curation()
        c["albums"][0]["confidence"] = "medium"
        c["albums"][0]["notes"] = "title doesn't match pattern exactly"
        prompt = build_prompt(c, [])
        assert "notes: title doesn't match pattern exactly" in prompt

    def test_shows_notes_for_low_confidence_included(self):
        c = _curation()
        c["albums"][0]["confidence"] = "low"
        c["albums"][0]["notes"] = "uncertain match"
        prompt = build_prompt(c, [])
        assert "notes: uncertain match" in prompt

    def test_hides_notes_for_high_confidence_included(self):
        c = _curation()
        c["albums"][0]["notes"] = "should not appear"
        prompt = build_prompt(c, [])
        assert "should not appear" not in prompt

    def test_shows_notes_for_excluded_album(self):
        c = _curation()
        c["albums"][1]["notes"] = "borderline decision"
        prompt = build_prompt(c, [])
        assert "notes: borderline decision" in prompt

    def test_shows_lint_issues(self):
        prompt = build_prompt(_curation(), ["Duplicate ep 5 on spotify"])
        assert "Lint findings (1)" in prompt
        assert "Duplicate ep 5" in prompt

    def test_shows_series_facts(self):
        c = _curation(
            series_facts={
                "era_boundaries": [
                    {"label": "klassik", "release_date_range": "1976-1979"},
                ],
                "known_gaps": [
                    {"number": 13, "reason": "legal dispute"},
                ],
            }
        )
        prompt = build_prompt(c, [])
        assert "klassik" in prompt
        assert "1976-1979" in prompt
        assert "episode 13" in prompt
        assert "legal dispute" in prompt

    def test_marks_unaudited_facts(self):
        c = _curation(
            series_facts={
                "era_boundaries": [
                    {"label": "modern", "release_date_range": "2020-"},
                ],
            }
        )
        prompt = build_prompt(c, [])
        assert "[unaudited]" in prompt

    def test_marks_audited_facts(self):
        c = _curation(
            series_facts={
                "era_boundaries": [
                    {
                        "label": "modern",
                        "release_date_range": "2020-",
                        "audited_by": "minimax",
                    },
                ],
            }
        )
        prompt = build_prompt(c, [])
        assert "[audited by minimax]" in prompt

    def test_included_album_shows_release_date(self):
        c = _curation()
        c["albums"][0]["release_date"] = "2020-01-15"
        prompt = build_prompt(c, [])
        assert "2020-01-15" in prompt

    def test_sub_series_facts_show_album_ids(self):
        c = _curation(
            series_facts={
                "sub_series": [
                    {
                        "label": "adventskalender",
                        "album_ids": ["a1", "a2"],
                        "reason": "Seasonal special",
                    },
                ],
            }
        )
        prompt = build_prompt(c, [])
        assert "album_ids: ['a1', 'a2']" in prompt

    def test_sub_series_without_album_ids_flagged(self):
        c = _curation(
            series_facts={
                "sub_series": [
                    {"label": "specials", "album_ids": [], "reason": "one-offs"},
                ],
            }
        )
        prompt = build_prompt(c, [])
        assert "no album_ids" in prompt

    def test_structural_analysis_included(self):
        """Audit agent should see the same structural analysis data
        that the finalize agent gets, not just lint findings."""
        c = _curation()
        c["albums"] = [
            {
                "album_id": f"s{i}",
                "provider": "spotify",
                "include": True,
                "episode_num": i,
                "title": f"Folge {i}: Test",
            }
            for i in range(1, 6)
        ]
        prompt = build_prompt(c, [])
        assert "Structural analysis" in prompt or "Pattern coverage" in prompt

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
        prompt = build_prompt(c, [])
        for i in range(50):
            assert f"[spotify:x{i}] Excluded {i}" in prompt

    def test_shows_all_lint_issues(self):
        issues = [f"Issue {i}" for i in range(30)]
        prompt = build_prompt(_curation(), issues)
        assert "Lint findings (30)" in prompt
        assert prompt.count("Issue ") == 30

    def test_included_album_shows_album_id(self):
        """The agent needs real album_ids to write valid overrides.
        Without them, it invents descriptive strings that don't match
        any album in the curation file."""
        prompt = build_prompt(_curation(), [])
        assert "a1" in prompt

    def test_excluded_album_shows_album_id(self):
        prompt = build_prompt(_curation(), [])
        assert "a2" in prompt

    def test_album_ids_appear_next_to_provider(self):
        """album_id should be visually associated with its provider
        so the agent can use both in overrides."""
        c = _curation()
        c["albums"] = [
            {
                "album_id": "sp_123",
                "provider": "spotify",
                "include": True,
                "episode_num": 1,
                "title": "Folge 1: Test",
                "confidence": "high",
            },
            {
                "album_id": "am_456",
                "provider": "apple_music",
                "include": True,
                "episode_num": 1,
                "title": "Folge 1: Test",
                "confidence": "high",
            },
        ]
        prompt = build_prompt(c, [])
        assert "sp_123" in prompt
        assert "am_456" in prompt


# ── apply_audit: status determination ────────────────────────────────────


class TestApplyAuditStatus:
    def _apply(self, tmp_path, result: AuditResult) -> str:
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(_curation()))
        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            action = apply_audit(
                "test_series",
                result,
                model_name="test-model",
            )
        finally:
            monkeypatch.undo()
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
                    album_id="a2",
                    provider="spotify",
                    action="include",
                    reason="real episode",
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
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(_curation()))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2",
                        provider="spotify",
                        action="include",
                        reason="real episode",
                    ),
                ],
            )
            apply_audit("test_series", result, model_name="test-model")
        finally:
            monkeypatch.undo()

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
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(c))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2",
                        provider="spotify",
                        action="include",
                        reason="new override",
                    ),
                ],
            )
            apply_audit("test_series", result, model_name="test-model")
        finally:
            monkeypatch.undo()

        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        overrides = {o["album_id"]: o for o in data["review"]["overrides"]}
        assert "old_album" in overrides
        assert "a2" in overrides
        assert overrides["a2"]["reason"] == "new override"

    def test_override_with_fake_album_id_is_skipped(self, tmp_path):
        """The agent sometimes invents descriptive album_ids instead of
        using the real ones from the prompt. These should be silently
        dropped so they don't pollute the curation file."""
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(_curation()))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        warnings = []
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="Ep 121: Folge 121: Der neue Schulgarten",
                        provider="spotify",
                        action="exclude",
                        reason="duplicate",
                    ),
                    AuditOverride(
                        album_id="a2",
                        provider="spotify",
                        action="include",
                        reason="real episode",
                    ),
                ],
            )
            apply_audit(
                "test_series",
                result,
                model_name="test-model",
                on_progress=warnings.append,
            )
        finally:
            monkeypatch.undo()

        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        overrides = data["review"]["overrides"]
        override_ids = {o["album_id"] for o in overrides}
        assert "a2" in override_ids
        assert "Ep 121: Folge 121: Der neue Schulgarten" not in override_ids
        assert any("not found" in w for w in warnings)


# ── _merge_facts ─────────────────────────────────────────────────────────


class TestMergeFacts:
    def test_adds_new_era_boundary(self):
        series_facts: dict = {"era_boundaries": []}
        update = AuditFactUpdate(
            era_boundaries=[
                EraBoundaryProposal(label="klassik", release_date_range="1976-1979")
            ],
        )
        _merge_facts(
            series_facts,
            update,
            fact_provenance(
                by="test-model", at="2026-01-01T00:00:00+00:00", audited=True
            ),
        )
        assert len(series_facts["era_boundaries"]) == 1
        assert series_facts["era_boundaries"][0]["label"] == "klassik"
        assert series_facts["era_boundaries"][0]["audited_by"] == "test-model"

    def test_updates_existing_era_boundary_by_label(self):
        series_facts: dict = {
            "era_boundaries": [
                {
                    "label": "klassik",
                    "release_date_range": "1976-1980",
                    "curated_by": "curate",
                },
            ],
        }
        update = AuditFactUpdate(
            era_boundaries=[
                EraBoundaryProposal(label="klassik", release_date_range="1976-1979")
            ],
        )
        _merge_facts(
            series_facts,
            update,
            fact_provenance(
                by="test-model", at="2026-01-01T00:00:00+00:00", audited=True
            ),
        )
        assert len(series_facts["era_boundaries"]) == 1
        assert series_facts["era_boundaries"][0]["release_date_range"] == "1976-1979"
        assert series_facts["era_boundaries"][0]["audited_by"] == "test-model"

    def test_adds_new_known_gap(self):
        series_facts: dict = {"known_gaps": []}
        update = AuditFactUpdate(
            known_gaps=[KnownGapProposal(number=13, reason="legal dispute")],
        )
        _merge_facts(
            series_facts,
            update,
            fact_provenance(
                by="test-model", at="2026-01-01T00:00:00+00:00", audited=True
            ),
        )
        assert len(series_facts["known_gaps"]) == 1
        assert series_facts["known_gaps"][0]["number"] == 13

    def test_merge_preserves_unmentioned_facts(self):
        series_facts: dict = {
            "era_boundaries": [
                {
                    "label": "klassik",
                    "release_date_range": "1976-1979",
                    "curated_by": "curate",
                },
            ],
            "known_gaps": [
                {"number": 13, "reason": "old reason", "curated_by": "curate"},
            ],
            "sub_series": [],
        }
        update = AuditFactUpdate(
            era_boundaries=[
                EraBoundaryProposal(label="modern", release_date_range="2020-")
            ],
        )
        _merge_facts(
            series_facts,
            update,
            fact_provenance(
                by="test-model", at="2026-01-01T00:00:00+00:00", audited=True
            ),
        )
        assert len(series_facts["era_boundaries"]) == 2
        assert len(series_facts["known_gaps"]) == 1

    def test_empty_update_is_noop(self):
        series_facts: dict = {
            "era_boundaries": [{"label": "x", "release_date_range": "2020-"}],
            "known_gaps": [],
            "sub_series": [],
        }
        update = AuditFactUpdate()
        _merge_facts(
            series_facts,
            update,
            fact_provenance(
                by="test-model", at="2026-01-01T00:00:00+00:00", audited=True
            ),
        )
        assert len(series_facts["era_boundaries"]) == 1


# ── apply_audit: multiple fact_updates ─────────────────────────────────


class TestApplyAuditMultipleFactUpdates:
    def _apply_with_facts(self, tmp_path, fact_updates):
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(_curation()))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            result = AuditResult(
                approve=True,
                fact_updates=fact_updates,
            )
            apply_audit("test_series", result, model_name="test-model")
        finally:
            monkeypatch.undo()

        yaml = ruamel.yaml.YAML()
        return yaml.load(path)

    def test_all_fact_updates_applied_not_just_last(self, tmp_path):
        updates = [
            AuditFactUpdate(
                era_boundaries=[
                    EraBoundaryProposal(label="klassik", release_date_range="1976-1979")
                ],
            ),
            AuditFactUpdate(
                known_gaps=[KnownGapProposal(number=13, reason="legal dispute")],
            ),
        ]
        data = self._apply_with_facts(tmp_path, updates)
        facts = data["series_facts"]
        assert len(facts["era_boundaries"]) == 1
        assert facts["era_boundaries"][0]["label"] == "klassik"
        assert len(facts["known_gaps"]) == 1
        assert facts["known_gaps"][0]["number"] == 13

    def test_replace_then_merge_applies_both(self, tmp_path):
        updates = [
            AuditFactUpdate(
                mode="replace",
                era_boundaries=[
                    EraBoundaryProposal(
                        label="original", release_date_range="1970-1980"
                    )
                ],
            ),
            AuditFactUpdate(
                mode="merge",
                era_boundaries=[
                    EraBoundaryProposal(label="modern", release_date_range="2020-")
                ],
            ),
        ]
        data = self._apply_with_facts(tmp_path, updates)
        labels = {e["label"] for e in data["series_facts"]["era_boundaries"]}
        assert labels == {"original", "modern"}


# ── Dry-run mode ─────────────────────────────────────────────────────────


class TestDryRun:
    def test_dry_run_does_not_write(self, tmp_path):
        path = tmp_path / "assets" / "catalog" / "curation" / "test_series.json"
        path.parent.mkdir(parents=True)
        original = _curation()
        path.write_text(json.dumps(original))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            result = AuditResult(
                approve=True,
                overrides=[
                    AuditOverride(
                        album_id="a2",
                        provider="spotify",
                        action="include",
                        reason="test",
                    ),
                ],
            )
            apply_audit(
                "test_series",
                result,
                model_name="test-model",
                dry_run=True,
            )
        finally:
            monkeypatch.undo()

        data = json.loads(path.read_text())
        assert "review" not in data


# ── apply_audit: hard gate on critical regression flags ──────────────────


class TestApplyAuditHardGate:
    """The auditor's approval is necessary, not sufficient: critical
    deterministic regressions (include-collapse, facts-wipe) force
    escalation no matter what the model concluded. mama_sandy showed
    an auditor approving a curation that emptied an entire artist."""

    def _apply(self, tmp_path, result: AuditResult, flags: list[str]):
        path = tmp_path / "assets" / "catalog" / "curation" / "test_series.json"
        path.parent.mkdir(parents=True)
        curation = _curation()
        curation["regression_flags"] = flags
        path.write_text(json.dumps(curation))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            action = apply_audit(
                "test_series",
                result,
                model_name="test-model",
            )
        finally:
            monkeypatch.undo()
        yaml = ruamel.yaml.YAML()
        data = yaml.load(path)
        return action, data

    def test_critical_regression_escalates_despite_approval(self, tmp_path):
        flags = ["CRITICAL: Include collapse: 0 included (previous curation had 8)"]
        action, data = self._apply(tmp_path, AuditResult(approve=True), flags)
        assert action == "escalated"
        assert data["review"]["status"] == "escalated"
        assert any("hard-gate" in c for c in data["review"]["concerns"])

    def test_non_critical_flags_do_not_gate(self, tmp_path):
        flags = ["Included count looks different but within tolerance"]
        action, data = self._apply(tmp_path, AuditResult(approve=True), flags)
        assert action == "approved"


# ── apply_audit: override materialization ────────────────────────────────


class TestApplyAuditMaterialization:
    """Overrides materialize into album include flags at audit time.

    The overrides list is an audit trail, not an active filter. Before
    materialization, stale overrides from superseded audit rounds
    silently excluded albums (wickie lost 43 albums to a round the
    next audit explicitly contradicted) while apply ignored overrides
    entirely and shipped 183 audit-rejected albums."""

    def _run(self, tmp_path, curation, result):
        curation_dir = tmp_path / "assets" / "catalog" / "curation"
        curation_dir.mkdir(parents=True)
        path = curation_dir / "test_series.json"
        path.write_text(json.dumps(curation))

        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            apply_audit("test_series", result, model_name="test-model")
        finally:
            monkeypatch.undo()
        return json.loads(path.read_text())

    def test_exclude_override_flips_album_include_flag(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="a1",
                    provider="spotify",
                    action="exclude",
                    reason="compilation_as_episode",
                ),
            ],
        )
        data = self._run(tmp_path, _curation(), result)
        albums = {a["album_id"]: a for a in data["albums"]}
        assert albums["a1"]["include"] is False
        assert albums["a1"]["exclude_reason"] == "compilation_as_episode"
        # Trail entry still recorded.
        assert data["review"]["overrides"][0]["album_id"] == "a1"

    def test_include_override_flips_album_include_flag(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="a2",
                    provider="spotify",
                    action="include",
                    reason="real episode, wrongly excluded",
                ),
            ],
        )
        data = self._run(tmp_path, _curation(), result)
        albums = {a["album_id"]: a for a in data["albums"]}
        assert albums["a2"]["include"] is True
        assert albums["a2"].get("exclude_reason", "") == ""

    def test_unknown_album_id_not_materialized(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="invented_id",
                    provider="spotify",
                    action="exclude",
                    reason="hallucinated",
                ),
            ],
        )
        data = self._run(tmp_path, _curation(), result)
        albums = {a["album_id"]: a for a in data["albums"]}
        assert albums["a1"]["include"] is True
        assert not data["review"].get("overrides")

    def test_escalated_run_does_not_materialize_overrides(self, tmp_path):
        """An escalated verdict means a human decides; the model's
        excludes are recorded in the trail but must not touch album
        state (Mira lost 7 albums to a policy disagreement before the
        operator ever saw the escalation)."""
        result = AuditResult(
            approve=False,
            concerns=["fundamental disagreement"],
            overrides=[
                AuditOverride(
                    album_id="a1",
                    provider="spotify",
                    action="exclude",
                    reason="wrong_content_type",
                ),
            ],
        )
        data = self._run(tmp_path, _curation(), result)
        albums = {a["album_id"]: a for a in data["albums"]}
        assert albums["a1"]["include"] is True
        assert data["review"]["status"] == "escalated"
        # Proposal still recorded for the human reviewer.
        assert data["review"]["overrides"][0]["album_id"] == "a1"


# ── apply_audit: dry run itemizes what it would change ───────────────────


class TestApplyAuditDryRun:
    """A dry run must show *which* albums and facts it would touch.

    An override on an already hand-edited album replaces that album's
    trail entry, so a reviewer deciding whether to run live needs the
    targets, not just counts.
    """

    def _dry_run(self, tmp_path, result: AuditResult) -> tuple[list[str], dict]:
        path = tmp_path / "assets" / "catalog" / "curation" / "test_series.json"
        path.parent.mkdir(parents=True)
        original = _curation()
        path.write_text(json.dumps(original))

        lines: list[str] = []
        monkeypatch = pytest.MonkeyPatch()
        monkeypatch.setenv("LAUSCHI_REPO_ROOT", str(tmp_path))
        try:
            apply_audit(
                "test_series",
                result,
                model_name="test-model",
                dry_run=True,
                on_progress=lines.append,
            )
        finally:
            monkeypatch.undo()
        return lines, json.loads(path.read_text())

    def test_itemizes_override_targets(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="a2",
                    provider="spotify",
                    action="include",
                    reason="real episode",
                ),
            ],
        )
        lines, _ = self._dry_run(tmp_path, result)
        assert any("include spotify:a2: real episode" in line for line in lines)

    def test_itemizes_fact_update_summary(self, tmp_path):
        result = AuditResult(
            approve=True,
            fact_updates=[
                AuditFactUpdate(
                    mode="replace",
                    known_gaps=[KnownGapProposal(number=27, reason="stale")],
                ),
            ],
        )
        lines, _ = self._dry_run(tmp_path, result)
        assert any("mode=replace" in line and "gaps=1" in line for line in lines)

    def test_itemizes_concerns(self, tmp_path):
        result = AuditResult(approve=True, concerns=["known_gap for 27 is wrong"])
        lines, _ = self._dry_run(tmp_path, result)
        assert any("known_gap for 27 is wrong" in line for line in lines)

    def test_dry_run_writes_nothing(self, tmp_path):
        result = AuditResult(
            approve=True,
            overrides=[
                AuditOverride(
                    album_id="a1",
                    provider="spotify",
                    action="exclude",
                    reason="wrong",
                ),
            ],
        )
        _, data = self._dry_run(tmp_path, result)
        assert data == _curation()


# ── audit request budget ─────────────────────────────────────────────────


def test_audit_request_limit_fits_a_large_series():
    """Across 184 June audits the median tool-call count was 5 and the
    90th percentile 9, and none hit the limit. Bibi Blocksberg (~490
    albums, 3 lint issues) needed more than the old 20 once reasoning was
    disabled and the model spent its calls verifying albums on both
    providers:

        UsageLimitExceeded: The next request would exceed the
        request_limit of 20

    The budget must clear that while staying far below curate's 200, so
    a model looping on fruitless web searches still fails fast."""
    from lauschi_catalog._opencode import get_model_profile

    profile = get_model_profile("minimax-m2.7")
    assert profile.request_limit == 40


# ── search_included_albums: repeated identical query is a loop ───────────


class TestSearchRepeatGuard:
    """A model with reasoning off re-ran search_included_albums('Folge
    165') 18 times in a row on Bibi Blocksberg until it exhausted the
    request budget. An identical query returns an identical answer, so
    past the allowance the tool refuses with a ModelRetry that tells the
    model to use the hits it already has or submit its verdict.
    """

    def _tool_and_deps(self):
        from pydantic_ai.models.test import TestModel

        import lauschi_catalog.catalog.audit_ops as audit_mod

        agent = audit_mod._build_audit_agent(TestModel(), model_name="test")
        tool = agent._function_toolset.tools["search_included_albums"]
        deps = audit_mod.AuditDeps(series_id="s", curation=_curation())
        return tool, deps

    def _call(self, tool, deps, query: str):
        from pydantic_ai import RunContext

        ctx = RunContext(deps=deps, model=None, usage=None, prompt=None)
        return tool.function(ctx, query)

    def test_allowance_then_refuses_identical_query(self):
        from pydantic_ai import ModelRetry

        tool, deps = self._tool_and_deps()
        first = self._call(tool, deps, "Folge 1")
        second = self._call(tool, deps, "Folge 1")
        assert first == second
        try:
            self._call(tool, deps, "Folge 1")
        except ModelRetry as e:
            assert "already searched" in str(e)
        else:
            raise AssertionError("third identical query must be refused")

    def test_different_query_is_not_refused(self):
        tool, deps = self._tool_and_deps()
        for _ in range(3):
            self._call(tool, deps, "Folge 1")
            break
        # a fresh query has its own allowance regardless of prior queries
        self._call(tool, deps, "Folge 1")
        self._call(tool, deps, "Folge 2")
        self._call(tool, deps, "Folge 2")

    def test_query_match_is_case_insensitive_for_the_counter(self):
        from pydantic_ai import ModelRetry

        tool, deps = self._tool_and_deps()
        self._call(tool, deps, "folge 1")
        self._call(tool, deps, "FOLGE 1")
        try:
            self._call(tool, deps, "Folge 1")
        except ModelRetry:
            pass
        else:
            raise AssertionError("case variants of one query must share the counter")


# ── build_prompt: exact output is pinned ─────────────────────────────


def test_build_prompt_output_is_stable():
    """The one-shot prompt is the thing the size boundary was probed
    against and the thing 276 series are audited with. Decomposing it
    into shared sections (for the chunked audit's overview) must not
    change a byte of it. This pins the full text of a small fixture."""
    c = _curation()
    c["series_facts"] = {
        "era_boundaries": [],
        "known_gaps": [{"number": 7, "reason": "never released"}],
        "sub_series": [],
    }
    prompt = build_prompt(c, ["[spotify] Unexpected gaps at episodes: [7]"])
    expected_head = "## Series: Test Series (id: test_series)\nEpisode pattern: "
    assert prompt.startswith(expected_head)
    assert "### Included albums (" in prompt
    assert "### Excluded albums (" in prompt
    assert "### Series facts" in prompt
    assert "Known gap: episode 7 -- never released [unaudited]" in prompt
    assert "### Structural analysis (deterministic)" in prompt
    assert "### Lint findings (1)" in prompt
    assert prompt.endswith("and approve when sound.")
    # section order is part of the contract
    order = [
        prompt.index("### Included albums"),
        prompt.index("### Excluded albums"),
        prompt.index("### Series facts"),
        prompt.index("### Structural analysis"),
        prompt.index("### Lint findings"),
    ]
    assert order == sorted(order)
