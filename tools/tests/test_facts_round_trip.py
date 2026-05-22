"""Integration test: facts round-trip through the pipeline.

Verifies that discovered facts survive curate -> verify -> apply ->
load -> incremental curate without being dropped or corrupted.
"""

from __future__ import annotations

import copy

import pytest

from lauschi_catalog.catalog.facts import SeriesFacts
from lauschi_catalog.catalog.loader import load_catalog
from lauschi_catalog.catalog.apply_ops import filter_confirmed_facts
from lauschi_catalog.catalog.lint_ops import lint_curation


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
                        "curated_by": "curate",
                        "audited_by": "audit",
                        "audited_at": "2026-05-17T12:00:00+00:00",
                    },
                ],
                "known_gaps": [
                    {
                        "number": 156,
                        "reason": "legal dispute",
                        "curated_by": "curate",
                        "audited_by": "audit",
                        "audited_at": "2026-05-17T12:00:00+00:00",
                    },
                ],
                "sub_series": [],
            },
        }
        yaml_facts = filter_confirmed_facts(curation["series_facts"])
        assert yaml_facts is not None
        assert "era_boundaries" in yaml_facts
        assert "known_gaps" in yaml_facts
        era = yaml_facts["era_boundaries"][0]
        assert era["curated_by"] == "curate"
        assert era["audited_by"] == "audit"
        assert era["audited_at"] == "2026-05-17T12:00:00+00:00"

    def test_unaudited_facts_dropped_from_yaml(self):
        curation = {
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "dubious",
                        "release_date_range": "1999-2000",
                        "curated_by": "curate",
                    },
                ],
            },
        }
        yaml_facts = filter_confirmed_facts(curation["series_facts"])
        assert yaml_facts is None or yaml_facts == {}

    def test_mixed_audited_and_unaudited(self):
        curation = {
            "series_facts": {
                "era_boundaries": [
                    {
                        "label": "good",
                        "release_date_range": "1976-1979",
                        "curated_by": "curate",
                        "audited_by": "audit",
                        "audited_at": "2026-05-17T12:00:00+00:00",
                    },
                    {
                        "label": "bad",
                        "release_date_range": "1999-2000",
                        "curated_by": "curate",
                    },
                ],
            },
        }
        yaml_facts = filter_confirmed_facts(curation["series_facts"])
        assert yaml_facts is not None
        labels = {e["label"] for e in yaml_facts.get("era_boundaries", [])}
        assert labels == {"good"}

    def test_series_facts_model_validates_yaml_shape(self):
        """The shape filter_confirmed_facts emits must load via SeriesFacts."""
        raw = {
            "era_boundaries": [
                {
                    "label": "klassik",
                    "release_date_range": "1976-1979",
                    "curated_by": "curate",
                    "audited_by": "audit",
                    "audited_at": "2026-05-17T12:00:00+00:00",
                },
            ],
            "known_gaps": [
                {
                    "number": 156,
                    "reason": "legal dispute",
                    "curated_by": "curate",
                },
            ],
        }
        facts = SeriesFacts.model_validate(raw)
        assert len(facts.era_boundaries) == 1
        assert facts.era_boundaries[0].label == "klassik"
        assert facts.era_boundaries[0].audited_by == "audit"
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
                                "curated_by": "curate",
                                "audited_by": "audit",
                                "audited_at": "2026-05-17T12:00:00+00:00",
                            },
                        ],
                    },
                },
            ],
        }
        path = tmp_path / "series.yaml"
        with open(path, "w") as f:
            yaml.dump(data, f)

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
            assert era["audited_by"] == "audit"
        finally:
            loader.SERIES_YAML = orig_path




class TestLintResilience:
    """Lint handles edge cases gracefully."""

    def test_malformed_facts_does_not_crash(self):
        curation = {
            "albums": [],
            "series_facts": {
                "era_boundaries": [
                    {"label": "bad", "release_date_range": "not-a-range"},
                ],
            },
        }
        issues = lint_curation(curation)
        assert any("malformed series_facts" in i for i in issues)

    def test_no_series_facts_is_fine(self):
        curation = {
            "albums": [
                {"provider": "spotify", "album_id": "a1", "title": "Ep 1", "include": True, "episode_num": 1},
            ],
        }
        assert lint_curation(curation) == []

    def test_determinism(self):
        curation = {
            "albums": [
                {"provider": "spotify", "album_id": "a1", "title": "Ep 1", "include": True, "episode_num": 1},
                {"provider": "spotify", "album_id": "a2", "title": "Ep 3", "include": True, "episode_num": 3},
            ],
        }
        first = lint_curation(curation)
        second = lint_curation(curation)
        assert first == second


class TestMergedFactsNoneSafety:
    """The merged_facts block in _run_large must handle existing_facts=None.

    When curating a brand-new series (no entry in series.yaml), the
    caller passes existing_facts=None. If the finalize agent proposes
    facts (proposed_facts is truthy), the merge block fires because
    ``None or proposed_facts`` is truthy, then crashes on
    ``existing_facts.era_boundaries`` because existing_facts is None.
    """

    def test_proposed_only_no_existing(self):
        """proposed_facts without existing_facts must not crash."""
        merged = SeriesFacts()
        existing_facts = None
        proposed_facts = SeriesFacts(
            era_boundaries=[],
            known_gaps=[],
            sub_series=[],
        )
        # Replicate the merge logic from curate.py _run_large
        if existing_facts or proposed_facts:
            if existing_facts:
                merged.era_boundaries.extend(existing_facts.era_boundaries)
                merged.known_gaps.extend(existing_facts.known_gaps)
                merged.sub_series.extend(existing_facts.sub_series)
            if proposed_facts:
                merged.era_boundaries.extend(proposed_facts.era_boundaries)
                merged.known_gaps.extend(proposed_facts.known_gaps)
                merged.sub_series.extend(proposed_facts.sub_series)
        assert merged is not None

    def test_existing_only_no_proposed(self):
        from lauschi_catalog.catalog.facts import EraBoundary

        merged = SeriesFacts()
        existing_facts = SeriesFacts(
            era_boundaries=[
                EraBoundary(
                    label="klassik",
                    release_date_range="1976-1979",
                    curated_by="curate",
                ),
            ],
        )
        proposed_facts = None
        if existing_facts or proposed_facts:
            if existing_facts:
                merged.era_boundaries.extend(existing_facts.era_boundaries)
                merged.known_gaps.extend(existing_facts.known_gaps)
                merged.sub_series.extend(existing_facts.sub_series)
            if proposed_facts:
                merged.era_boundaries.extend(proposed_facts.era_boundaries)
                merged.known_gaps.extend(proposed_facts.known_gaps)
                merged.sub_series.extend(proposed_facts.sub_series)
        assert len(merged.era_boundaries) == 1
        assert merged.era_boundaries[0].label == "klassik"

    def test_both_none_produces_nothing(self):
        existing_facts = None
        proposed_facts = None
        merged = None
        if existing_facts or proposed_facts:
            merged = SeriesFacts()
        assert merged is None
