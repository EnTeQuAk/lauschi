"""What an eval case reports about a batch of decisions.

A catalog gets worse in three ways: an album ships that should not, an
album that should ship is missing, or an album ships under the wrong
number. The evaluators count these apart, since they do not weigh the
same and a single pass or fail per case hides which one happened.
"""

from typing import Any

from pydantic_evals import Case, Dataset
from pydantic_evals.evaluators import EvaluationReason, EvaluatorContext
from pydantic_evals.otel import SpanTreeRecordingError
from pydantic_evals.reporting.analyses import TableResult

from lauschi_catalog.catalog.curate_ops import AlbumDecision, BatchResult
from tests.evals.evaluators import CatalogOutcome, CatalogTotals, EpisodeNumbersCorrect
from tests.factories import decision

Expected = dict[tuple[str, str], dict[str, Any]]


def _context(expected: Expected, decisions: list[AlbumDecision]) -> EvaluatorContext:
    return EvaluatorContext(
        name="case",
        inputs=None,
        metadata=expected,
        expected_output=None,
        output=BatchResult(albums=decisions),
        duration=0.0,
        _span_tree=SpanTreeRecordingError("not recorded"),
        attributes={},
        metrics={},
    )


def _key(album_id: str) -> tuple[str, str]:
    return ("spotify", album_id)


EXPECTED: Expected = {
    _key("ep1"): {
        "include": True,
        "episode_num": 1,
        "source": "line index: Hörspiele 1",
    },
    _key("ep2"): {
        "include": True,
        "episode_num": 2,
        "source": "line index: Hörspiele 2",
    },
    _key("special"): {"include": True, "episode_num": None, "source": "by hand"},
    _key("ost"): {"include": False, "source": "by hand"},
}


class TestCatalogOutcome:
    def test_every_decision_as_expected(self) -> None:
        decisions = [
            decision("ep1", episode_num=1),
            decision("ep2", episode_num=2),
            decision("special"),
            decision("ost", include=False, exclude_reason="wrong_content_type"),
        ]

        assert CatalogOutcome().evaluate(_context(EXPECTED, decisions)) == {
            "right": 1.0,
            "wrong_content": 0,
            "missing_content": 0,
        }

    def test_wrong_and_missing_content_are_counted_apart(self) -> None:
        decisions = [
            decision("ep1", episode_num=1),
            decision("ep2", include=False, exclude_reason="compilation"),
            decision("special", include=False, exclude_reason="compilation"),
            decision("ost"),
        ]

        assert CatalogOutcome().evaluate(_context(EXPECTED, decisions)) == {
            "right": 0.25,
            "wrong_content": 1,
            "missing_content": 2,
        }

    def test_an_album_without_a_decision_is_not_right(self) -> None:
        decisions = [decision("ep1", episode_num=1)]

        outcome = CatalogOutcome().evaluate(_context(EXPECTED, decisions))

        assert outcome == {"right": 0.25, "wrong_content": 0, "missing_content": 2}


class TestEpisodeNumbersCorrect:
    def test_the_numbers_the_case_names_ship(self) -> None:
        decisions = [
            decision("ep1", episode_num=1),
            decision("ep2", episode_num=2),
            decision("special"),
        ]

        result = EpisodeNumbersCorrect().evaluate(_context(EXPECTED, decisions))

        assert result == EvaluationReason(value=True, reason="3 number(s) as expected")

    def test_a_wrong_number_and_a_number_that_should_not_be_there(self) -> None:
        decisions = [
            decision("ep1", episode_num=1),
            decision("ep2", episode_num=8, title="Folge 8: Zwei"),
            decision("special", episode_num=5, title="Special"),
        ]

        result = EpisodeNumbersCorrect().evaluate(_context(EXPECTED, decisions))

        assert isinstance(result, EvaluationReason)
        assert result.value is False
        assert result.reason == (
            "spotify:ep2 (Folge 8: Zwei): ships as 8, expected 2; "
            "spotify:special (Special): ships as 5, expected no number"
        )

    def test_an_album_decided_wrongly_is_not_a_numbering_error(self) -> None:
        decisions = [
            decision("ep1", episode_num=1),
            decision("ep2", include=False, exclude_reason="compilation"),
        ]

        result = EpisodeNumbersCorrect().evaluate(_context(EXPECTED, decisions))

        assert result == EvaluationReason(value=True, reason="1 number(s) as expected")

    def test_a_case_that_names_no_number_reports_nothing(self) -> None:
        expected: Expected = {_key("a"): {"include": True, "source": "by hand"}}

        result = EpisodeNumbersCorrect().evaluate(_context(expected, [decision("a")]))

        assert result == {}


def test_the_report_adds_the_albums_of_all_cases_up() -> None:
    """A case average hides the size of a case: one wrong album in a case
    of two weighs as much as ten wrong in a case of twenty."""
    answers = {
        "small": [decision("ep1", episode_num=1), decision("ost")],
        "large": [
            decision("ep1", episode_num=1),
            decision("ep2", include=False, exclude_reason="compilation"),
            decision("special"),
            decision("ost", include=False, exclude_reason="wrong_content_type"),
        ],
    }
    dataset = Dataset(
        name="totals",
        cases=[
            Case(
                name="small",
                inputs="small",
                metadata={k: EXPECTED[k] for k in (_key("ep1"), _key("ost"))},
            ),
            Case(name="large", inputs="large", metadata=EXPECTED),
        ],
        report_evaluators=[CatalogTotals()],
    )

    report = dataset.evaluate_sync(
        lambda name: BatchResult(albums=answers[name]), progress=False
    )

    assert report.analyses == [
        TableResult(
            title="Albums across all cases",
            columns=["albums", "right", "wrong content", "missing content"],
            rows=[[6, 4, 1, 1]],
        )
    ]
