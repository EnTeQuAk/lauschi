from __future__ import annotations

from pydantic_ai.exceptions import UnexpectedModelBehavior

from lauschi_catalog.catalog.curate_ops import describe_failure


def _raise_chain() -> BaseException:
    try:
        try:
            raise ValueError("confidence != 'high' requires `notes` describing why")
        except ValueError as inner:
            raise UnexpectedModelBehavior(
                "Exceeded maximum output retries (2)"
            ) from inner
    except UnexpectedModelBehavior as outer:
        return outer


def test_the_reason_behind_a_retry_exhaustion_is_kept() -> None:
    text = describe_failure(_raise_chain())
    assert text.startswith(
        "UnexpectedModelBehavior: Exceeded maximum output retries (2)"
    )
    assert "ValueError: confidence != 'high' requires `notes`" in text


def test_an_exception_without_a_message_shows_its_type() -> None:
    assert describe_failure(TimeoutError()) == "TimeoutError"


def test_a_cycle_in_the_cause_chain_terminates() -> None:
    a = RuntimeError("a")
    b = RuntimeError("b")
    a.__cause__ = b
    b.__cause__ = a
    assert describe_failure(a) == "RuntimeError: a <- RuntimeError: b"
