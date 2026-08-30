import json
from pathlib import Path

import pytest

from lauschi_catalog.eval.report import (
    aggregate,
    render_details,
    render_table,
    write_json,
)
from lauschi_catalog.eval.score import Disagreement, Score
from lauschi_catalog.eval.truth import AlbumKey


def _score(series_id: str, **kw) -> Score:
    base = dict(
        series_id=series_id,
        model="m",
        include_precision=1.0,
        include_recall=1.0,
        hallucinated=frozenset(),
        gap_recovery=None,
        n_undecided=0,
        n_outside_truth=0,
        n_included=10,
        n_truth_included=10,
        incomplete=False,
        disagreements=(),
    )
    base.update(kw)
    return Score(**base)


class TestAggregate:
    def test_precision_and_recall_are_macro_averaged_per_series(self) -> None:
        agg = aggregate(
            [
                _score(
                    "small", include_precision=0.5, include_recall=0.5, n_included=2
                ),
                _score(
                    "huge", include_precision=1.0, include_recall=1.0, n_included=500
                ),
            ]
        )
        # a series is a series, whatever its size
        assert agg["include_precision"] == pytest.approx(0.75)
        assert agg["include_recall"] == pytest.approx(0.75)

    def test_hallucinations_are_totalled_and_named(self) -> None:
        agg = aggregate(
            [
                _score("clean"),
                _score(
                    "bad",
                    hallucinated=frozenset(
                        {AlbumKey("spotify", "x"), AlbumKey("spotify", "y")}
                    ),
                ),
            ]
        )
        assert agg["hallucinated_total"] == 2
        assert agg["series_with_hallucination"] == ["bad"]

    def test_gap_recovery_ignores_series_without_canon_gaps(self) -> None:
        agg = aggregate([_score("a", gap_recovery=None), _score("b", gap_recovery=0.5)])
        assert agg["gap_recovery"] == pytest.approx(0.5)

    def test_empty_input_does_not_divide_by_zero(self) -> None:
        agg = aggregate([])
        assert agg["n_series"] == 0
        assert agg["include_precision"] is None


class TestRender:
    def test_an_incomplete_run_is_labelled_in_its_row(self) -> None:
        table = render_table([_score("fuenf_freunde", incomplete=True)])
        assert "| fuenf_freunde (INCOMPLETE run) |" in table

    def test_details_list_each_disagreement_with_direction_and_reason(self) -> None:
        d = Disagreement(
            provider="spotify",
            album_id="x1",
            title="Folge 9: Box",
            truth_include=False,
            model_include=True,
            reason="",
        )
        e = Disagreement(
            provider="apple_music",
            album_id="y2",
            title="Folge 3",
            truth_include=True,
            model_include=False,
            reason="compilation",
        )
        text = render_details(
            [_score("kira_kolumna", disagreements=(d, e)), _score("clean")]
        )
        assert "kira_kolumna: 2 disagreement(s)" in text
        assert "truth OUT, model IN  spotify:x1  Folge 9: Box" in text
        assert "truth IN, model OUT  apple_music:y2  Folge 3  [compilation]" in text
        assert "clean" not in text

    def test_table_has_one_row_per_series_plus_mean(self) -> None:
        table = render_table([_score("kira_kolumna"), _score("paw_patrol")])
        lines = table.splitlines()
        assert lines[0].startswith("| series |")
        assert sum(1 for line in lines if line.startswith("| kira_kolumna")) == 1
        assert lines[-1].startswith("| **mean** |")

    def test_json_round_trips_hallucinations_as_readable_keys(
        self, tmp_path: Path
    ) -> None:
        out = tmp_path / "scores.json"
        write_json(
            [_score("bad", hallucinated=frozenset({AlbumKey("apple_music", "42")}))],
            out,
        )
        data = json.loads(out.read_text())
        assert data["aggregate"]["hallucinated_total"] == 1
        assert data["series"][0]["hallucinated"] == ["apple_music:42"]
