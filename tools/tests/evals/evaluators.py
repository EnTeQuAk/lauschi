"""Custom evaluators for catalog curation evals.

Deterministic checks for album decisions: correct include/exclude,
correct exclude_reason, confidence thresholds. Adapted from kaiko's
eval pattern.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic_evals.evaluators import Evaluator, EvaluatorContext, EvaluationReason


@dataclass
class DecisionsCorrect(Evaluator):
    """Check that every album's include/exclude decision matches expected.

    Expects metadata to be a dict mapping (provider, album_id) tuples
    to expected decisions:

        {("spotify", "abc123"): {"include": True}, ...}

    Fails if any album's include/exclude doesn't match. Reports which
    albums were wrong.
    """

    def get_default_evaluation_name(self) -> str:
        return "decisions_correct"

    def evaluate(self, ctx: EvaluatorContext) -> EvaluationReason:
        expected = ctx.metadata or {}
        decisions = ctx.output.albums
        decision_map = {(d.provider, d.album_id): d for d in decisions}

        wrong: list[str] = []
        missing: list[str] = []

        for key, exp in expected.items():
            provider, album_id = key
            decision = decision_map.get(key)
            if decision is None:
                missing.append(f"{provider}:{album_id}")
                continue
            if decision.include != exp["include"]:
                action = "included" if decision.include else "excluded"
                expected_action = "include" if exp["include"] else "exclude"
                wrong.append(
                    f"{provider}:{album_id} ({decision.title}): "
                    f"{action}, expected {expected_action}"
                )

        if wrong or missing:
            details = []
            if wrong:
                details.append(f"Wrong: {'; '.join(wrong)}")
            if missing:
                details.append(f"Missing from output: {', '.join(missing)}")
            return EvaluationReason(value=False, reason=". ".join(details))
        return EvaluationReason(value=True, reason="All decisions correct")


@dataclass
class ExcludeReasonsCorrect(Evaluator):
    """Check that excluded albums use the expected exclude_reason.

    Only checks albums where expected has an "exclude_reason" key.
    Skips albums that are expected to be included.

    The expected reason can be a single string or a list of acceptable
    alternatives (e.g. ["wrong_content_type", "kinderlieder_compilation"]
    when both are defensible).
    """

    def get_default_evaluation_name(self) -> str:
        return "exclude_reasons"

    def evaluate(self, ctx: EvaluatorContext) -> EvaluationReason:
        expected = ctx.metadata or {}
        decisions = ctx.output.albums
        decision_map = {(d.provider, d.album_id): d for d in decisions}

        wrong: list[str] = []

        for key, exp in expected.items():
            if exp.get("include", False):
                continue
            expected_reason = exp.get("exclude_reason")
            if expected_reason is None:
                continue
            provider, album_id = key
            decision = decision_map.get(key)
            if decision is None:
                continue
            if decision.include:
                continue
            actual = decision.exclude_reason or "unspecified"
            acceptable = expected_reason if isinstance(expected_reason, list) else [expected_reason]
            if actual not in acceptable:
                wrong.append(
                    f"{provider}:{album_id}: "
                    f"got '{actual}', expected one of {acceptable}"
                )

        if wrong:
            return EvaluationReason(
                value=False, reason=f"Wrong reasons: {'; '.join(wrong)}"
            )
        return EvaluationReason(value=True, reason="All exclude reasons correct")


CONFIDENCE_RANK = {"high": 3, "medium": 2, "low": 1}


@dataclass
class ConfidenceMinimum(Evaluator):
    """Check that decisions meet a minimum confidence threshold.

    Expects metadata entries with a "min_confidence" key. Fails if any
    decision's confidence is below the minimum.
    """

    def get_default_evaluation_name(self) -> str:
        return "confidence"

    def evaluate(self, ctx: EvaluatorContext) -> EvaluationReason:
        expected = ctx.metadata or {}
        decisions = ctx.output.albums
        decision_map = {(d.provider, d.album_id): d for d in decisions}

        low: list[str] = []

        for key, exp in expected.items():
            min_conf = exp.get("min_confidence")
            if min_conf is None:
                continue
            provider, album_id = key
            decision = decision_map.get(key)
            if decision is None:
                continue
            actual_rank = CONFIDENCE_RANK.get(decision.confidence, 0)
            min_rank = CONFIDENCE_RANK.get(min_conf, 0)
            if actual_rank < min_rank:
                low.append(
                    f"{provider}:{album_id}: "
                    f"got '{decision.confidence}', need >= '{min_conf}'"
                )

        if low:
            return EvaluationReason(
                value=False, reason=f"Below minimum: {'; '.join(low)}"
            )
        return EvaluationReason(value=True, reason="All confidence levels sufficient")


@dataclass
class NotesPresent(Evaluator):
    """Check that medium/low confidence decisions have notes.

    The AlbumDecision schema enforces this via a model_validator, but
    this evaluator catches cases where the model returns empty notes
    or generic filler.
    """

    min_note_length: int = 10

    def get_default_evaluation_name(self) -> str:
        return "notes_present"

    def evaluate(self, ctx: EvaluatorContext) -> EvaluationReason:
        decisions = ctx.output.albums
        missing: list[str] = []

        for d in decisions:
            if d.confidence == "high":
                continue
            if not d.notes or len(d.notes.strip()) < self.min_note_length:
                missing.append(
                    f"{d.provider}:{d.album_id} "
                    f"(confidence={d.confidence}, notes={d.notes!r})"
                )

        if missing:
            return EvaluationReason(
                value=False,
                reason=f"Missing/short notes on non-high: {'; '.join(missing)}",
            )
        return EvaluationReason(value=True, reason="All non-high decisions have notes")
