"""Integration test: facts round-trip through the pipeline.

Verifies that discovered facts survive curate -> verify -> apply ->
load -> incremental curate without being dropped or corrupted.
"""

from __future__ import annotations

import copy

import pytest

from lauschi_catalog.catalog.facts import SeriesFacts
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.commands.apply import _filter_confirmed_facts


class TestFactsRoundTrip:
    """White-box pipeline test using real functions."""

    def test_confirmed_facts_persist_to_yaml(self):
        curation = {
            "id": "test_series",
            "title": "Test Series",
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "klassik",
                        "release_date_range": "1976-1979",
                        "discovered_by": "curate",
                        "confirmed_by": "verify",
                        "confirmed_at": "2026-05-17T12:00:00+00:00",
                    },
                ],
                "known_gaps": [
                    {
                        "number": 156,
                        "reason": "legal dispute",
                        "discovered_by": "curate",
                        "confirmed_by": "verify",
                        "confirmed_at": "2026-05-17T12:00:00+00:00",
                    },
                ],
                "sub_series": [],
            },
        }
        yaml_facts = _filter_confirmed_facts(curation["series_facts"])
        assert yaml_facts is not None
        assert "era_boundaries" in yaml_facts
        assert "known_gaps" in yaml_facts
        # Provenance kept in yaml
        era = yaml_facts["era_boundaries"][0]
        assert era["discovered_by"] == "curate"
        assert era["confirmed_by"] == "verify"
        assert era["confirmed_at"] == "2026-05-17T12:00:00+00:00"
        # Verify-time fields stripped
        assert "verify_status" not in era
        assert "verify_reasoning" not in era

    def test_unconfirmed_facts_dropped_from_yaml(self):
        curation = {
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "dubious",
                        "release_date_range": "1999-2000",
                        "discovered_by": "curate",
                        "verify_status": "disagreed",
                        "verify_reasoning": "no albums in range",
                    },
                ],
            },
        }
        yaml_facts = _filter_confirmed_facts(curation["series_facts"])
        # No confirmed_by -> dropped entirely
        assert yaml_facts is None or yaml_facts == {}

    def test_mixed_confirmed_and_unconfirmed(self):
        curation = {
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "good",
                        "release_date_range": "1976-1979",
                        "discovered_by": "curate",
                        "confirmed_by": "verify",
                        "confirmed_at": "2026-05-17T12:00:00+00:00",
                    },
                    {
                        "label": "bad",
                        "release_date_range": "1999-2000",
                        "discovered_by": "curate",
                        "verify_status": "disagreed",
                        "verify_reasoning": "nope",
                    },
                ],
            },
        }
        yaml_facts = _filter_confirmed_facts(curation["series_facts"])
        assert yaml_facts is not None
        labels = {e["label"] for e in yaml_facts.get("era_boundaries", [])}
        assert labels == {"good"}

    def test_series_facts_model_validates_yaml_shape(self):
        """The shape _filter_confirmed_facts emits must load via SeriesFacts."""
        raw = {
            "era_boundaries": [
                {
                    "label": "klassik",
                    "release_date_range": "1976-1979",
                    "discovered_by": "curate",
                    "confirmed_by": "verify",
                    "confirmed_at": "2026-05-17T12:00:00+00:00",
                },
            ],
            "known_gaps": [
                {
                    "number": 156,
                    "reason": "legal dispute",
                    "discovered_by": "curate",
                },
            ],
        }
        facts = SeriesFacts.model_validate(raw)
        assert len(facts.era_boundaries) == 1
        assert facts.era_boundaries[0].label == "klassik"
        assert facts.era_boundaries[0].confirmed_by == "verify"
        assert len(facts.known_gaps) == 1
        assert facts.known_gaps[0].number == 156

    def test_load_catalog_reads_series_facts(self, tmp_path):
        """series.yaml with series_facts loads correctly into CatalogEntry."""
        import ruamel.yaml

        yaml = ruamel.yaml.YAML()
        data = {
            "series": [
                {
                    "id": "round_trip_test",
                    "title": "Round Trip Test",
                    "series_facts": {
                        "era_boundaries": [
                            {
                                "label": "modern",
                                "release_date_range": "2020-2022",
                                "discovered_by": "curate",
                                "confirmed_by": "verify",
                                "confirmed_at": "2026-05-17T12:00:00+00:00",
                            },
                        ],
                    },
                },
            ],
        }
        path = tmp_path / "series.yaml"
        with open(path, "w") as f:
            yaml.dump(data, f)

        # Monkeypatch loader to use our temp file
        import lauschi_catalog.catalog.loader as loader
        orig_path = loader.SERIES_YAML
        loader.SERIES_YAML = path
        try:
            entries = load_catalog(path)
            entry = entries[0]
            assert entry.id == "round_trip_test"
            assert entry.series_facts is not None
            assert "era_boundaries" in entry.series_facts
            era = entry.series_facts["era_boundaries"][0]
            assert era["label"] == "modern"
            assert era["confirmed_by"] == "verify"
        finally:
            loader.SERIES_YAML = orig_path

    def test_verify_stamps_per_fact(self):
        """apply_verification stamps confirmed_by per-fact on agreed, verify_status on disagreed."""
        import json
        from datetime import UTC, datetime
        from pathlib import Path

        from lauschi_catalog.commands.verify import apply_verification
        from lauschi_catalog.commands.verify import FactVerdict, VerifyResult

        # Minimal curation JSON on disk
        tmp_dir = Path("/tmp/test_verify_stamps")
        tmp_dir.mkdir(exist_ok=True)
        curation_path = tmp_dir / "test_series.json"
        curation = {
            "id": "test_series",
            "title": "Test",
            "albums": [],
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "good",
                        "release_date_range": "2020-2022",
                        "discovered_by": "curate",
                    },
                    {
                        "label": "bad",
                        "release_date_range": "1999-2000",
                        "discovered_by": "curate",
                    },
                ],
            },
            "review": {"status": "ai_reviewed"},
        }
        curation_path.write_text(json.dumps(curation))

        # Monkeypatch CURATION_DIR
        import lauschi_catalog.commands.verify as verify_mod
        orig_dir = verify_mod.CURATION_DIR
        verify_mod.CURATION_DIR = tmp_dir
        try:
            result = VerifyResult(
                series_id="test_series",
                approve=True,
                fact_verdicts=[
                    FactVerdict(fact_type="era_boundary", identifier="good", agree=True),
                    FactVerdict(fact_type="era_boundary", identifier="bad", agree=False, reason="no evidence"),
                ],
            )
            action = apply_verification("test_series", result, dry_run=False)
            assert action == "approved"

            updated = json.loads(curation_path.read_text())
            facts = updated["series_facts"]
            good = next(e for e in facts["era_boundaries"] if e["label"] == "good")
            bad = next(e for e in facts["era_boundaries"] if e["label"] == "bad")

            assert good["confirmed_by"] == "verify"
            assert "confirmed_at" in good
            assert good.get("verify_status") == "agreed"

            assert "confirmed_by" not in bad or bad["confirmed_by"] is None
            assert bad["verify_status"] == "disagreed"
            assert bad["verify_reasoning"] == "no evidence"
        finally:
            verify_mod.CURATION_DIR = orig_dir
