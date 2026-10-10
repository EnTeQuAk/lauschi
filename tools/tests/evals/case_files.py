"""Eval cases stored as files.

One JSON file per case under ``fixtures/``. It holds one batch frozen
from the provider cache (``albums``), the series facts and the prior
decisions the run would have (``series``, ``decided``), and for every
album the decision it must come out with (``expect``). An expectation
names its source: the line index where it lists the title, a hand
decision where it does not.
"""

import json
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from pydantic_evals import Case

from lauschi_catalog.catalog.curate_ops import AlbumDecision, BatchResult, ExcludeReason

from .task import BatchInput, SeriesContext

FIXTURES = Path(__file__).parent / "fixtures"


class Expectation(BaseModel):
    """The decision an album must come out with, and what it rests on."""

    model_config = ConfigDict(extra="forbid")

    include: bool
    #: one reason, or every reason that is defensible. Left out, any
    #: reason passes.
    exclude_reason: ExcludeReason | list[ExcludeReason] | None = None
    #: the number the album must ship with, null for none at all. Left
    #: out, the number is not checked.
    episode_num: int | None = None
    #: the least confidence the decision may come with. Left out, any
    #: confidence passes.
    min_confidence: Literal["high", "medium", "low"] | None = None
    #: "line index: <line> <number>" or "by hand: <why>"
    source: str = Field(min_length=1)

    @model_validator(mode="after")
    def _fits_the_decision(self) -> "Expectation":
        if self.include and self.exclude_reason is not None:
            raise ValueError("an included album cannot carry an exclude_reason")
        if not self.include and self.episode_num is not None:
            raise ValueError("an excluded album cannot carry an episode_num")
        return self


class _CaseFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    #: what the case finds out, in one sentence
    question: str = Field(min_length=1)
    series: SeriesContext
    decided: list[dict[str, Any]] = []
    albums: list[dict[str, Any]] = Field(min_length=1)


def load_case(path: Path) -> Case[BatchInput, BatchResult]:
    """Read one case file. The case is named after the file."""
    try:
        data = _CaseFile.model_validate(json.loads(path.read_text()))
    except ValidationError as exc:
        raise ValueError(f"{path.name}: {exc}") from exc

    decided = {(row["provider"], row["album_id"]) for row in data.decided}
    for row in data.decided:
        AlbumDecision.model_validate(row)

    albums: list[dict[str, Any]] = []
    expected: dict[tuple[str, str], dict[str, Any]] = {}
    for album in data.albums:
        key = (album["provider"], album["id"])
        name = f"{path.name}: {key[0]}:{key[1]}"
        if key in decided:
            raise ValueError(f"{name} is both asked and decided")
        try:
            expect = Expectation.model_validate(album.get("expect"))
        except ValidationError as exc:
            raise ValueError(f"{name}: {exc}") from exc
        expected[key] = expect.model_dump(exclude_unset=True)
        albums.append({k: v for k, v in album.items() if k != "expect"})

    return Case(
        name=path.stem,
        inputs=BatchInput(series=data.series, albums=albums, decided=data.decided),
        metadata=expected,
    )


def load_cases() -> list[Case[BatchInput, BatchResult]]:
    """Every case file, by name."""
    return [load_case(path) for path in sorted(FIXTURES.glob("*.json"))]
