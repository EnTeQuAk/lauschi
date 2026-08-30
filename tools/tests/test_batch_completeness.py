"""Tests for batch completeness validator set equality."""

import pytest
from pydantic_ai import RunContext
from pydantic_ai.models.test import TestModel

from lauschi_catalog.catalog.curate_ops import (
    AlbumDecision,
    BatchResult,
    CurateDeps,
    _build_batch_agent,
)


def _make_deps(batch_ids: set[tuple[str, str]]) -> CurateDeps:
    deps = CurateDeps(pattern=None, all_decisions=[])
    object.__setattr__(deps, "current_batch_ids", batch_ids)
    object.__setattr__(deps, "on_progress", lambda _m: None)
    return deps


def _ctx(deps: CurateDeps) -> RunContext:
    return RunContext(deps=deps, model=TestModel(call_tools=[]), usage=None)  # type: ignore[reportArgumentType]


def _decision(
    album_id: str,
    provider: str = "spotify",
    *,
    include: bool,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
) -> AlbumDecision:
    return AlbumDecision(
        album_id=album_id,
        provider=provider,
        title=f"T{album_id}",
        include=include,
        confidence="high",
        episode_num=episode_num,
        exclude_reason=exclude_reason,
    )


def _validator(deps: CurateDeps):
    agent = _build_batch_agent(TestModel(call_tools=[]), model_name="test")
    return agent._output_validators[0].function


def test_completeness_validator_rejects_missing_and_extra_albums():
    """A batch output must contain exactly the batch ids, no more, no less."""
    deps = _make_deps({("spotify", "a1"), ("spotify", "a2")})
    validate = _validator(deps)

    # Missing a2, added extra a3
    bad = BatchResult(
        albums=[
            _decision("a1", include=True, episode_num=1),
            _decision("a3", include=False, exclude_reason="compilation"),
        ]
    )

    with pytest.raises(Exception) as exc_info:
        validate(_ctx(deps), bad)

    msg = str(exc_info.value)
    assert "omitted 1" in msg
    assert "a2" in msg
    assert "added 1" in msg
    assert "a3" in msg


def test_completeness_validator_accepts_exact_batch():
    """A batch output matching the ids exactly passes."""
    deps = _make_deps({("spotify", "a1")})
    validate = _validator(deps)

    good = BatchResult(albums=[_decision("a1", include=True, episode_num=1)])

    result = validate(_ctx(deps), good)
    assert result is good


def test_completeness_validator_rejects_extra_only():
    """A batch with only extra ids is also rejected."""
    deps = _make_deps({("spotify", "a1")})
    validate = _validator(deps)

    extra = BatchResult(
        albums=[
            _decision("a1", include=True, episode_num=1),
            _decision("a2", include=False, exclude_reason="compilation"),
        ]
    )

    with pytest.raises(Exception) as exc_info:
        validate(_ctx(deps), extra)

    msg = str(exc_info.value)
    assert "added 1" in msg
    assert "a2" in msg


def test_batch_result_accepts_duplicate_album_keys():
    """Duplicate album keys are currently allowed by the model; the validator
    catches set inequality, not duplicates. This test documents the status quo.
    """
    result = BatchResult(
        albums=[
            _decision("a1", include=True, episode_num=1),
            _decision("a1", include=False, exclude_reason="compilation"),
        ]
    )
    assert len(result.albums) == 2
