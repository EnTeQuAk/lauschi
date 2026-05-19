"""Structured series facts discovered by the curation pipeline.

Facts like era_boundaries, known_gaps, and sub_series are discovered by
LLM agents during curation, audited by a second model (4-eye principle),
and then frozen into series.yaml. On subsequent runs (incremental
updates), curate loads the frozen facts as input context and only
proposes genuinely new ones.

Each fact carries provenance (curated_by, audited_by, audited_at)
so we can distinguish documented history from hallucination.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field, field_validator, model_validator


import re as _re


def _migrate_provenance(data: dict[str, Any]) -> dict[str, Any]:
    """Map old provenance field names to the current schema.

    Old: discovered_by, confirmed_by, confirmed_at, verify_status, verify_reasoning
    New: curated_by, audited_by, audited_at
    """
    if "discovered_by" in data and "curated_by" not in data:
        data["curated_by"] = data.pop("discovered_by")
    if "confirmed_by" in data and "audited_by" not in data:
        data["audited_by"] = data.pop("confirmed_by")
    if "confirmed_at" in data and "audited_at" not in data:
        data["audited_at"] = data.pop("confirmed_at")
    data.pop("verify_status", None)
    data.pop("verify_reasoning", None)
    return data


class EraBoundary(BaseModel):
    """A contiguous time period with a distinct naming convention."""

    label: str = Field(description="Short label, e.g. 'klassik', 'cgi_reboot'.")
    release_date_range: str = Field(
        description="Year range like '1976-1979' or '2015-2018' or '2025-'. "
        "The trailing dash means 'ongoing'.",
    )

    @field_validator("release_date_range", mode="before")
    @classmethod
    def _validate_range(cls, v: str) -> str:
        if not _re.fullmatch(r"^\d{4}-(\d{4})?$", v):
            msg = (
                f"release_date_range must be 'YYYY-YYYY' or 'YYYY-', "
                f"got {v!r}"
            )
            raise ValueError(msg)
        return v

    curated_by: str
    audited_by: str | None = Field(default=None)
    audited_at: str | None = Field(default=None)

    @model_validator(mode="before")
    @classmethod
    def _migrate(cls, data: Any) -> Any:
        if isinstance(data, dict):
            return _migrate_provenance(data)
        return data


class KnownGap(BaseModel):
    """A documented missing episode number, not a curation error."""

    number: int
    reason: str = Field(
        description="Why this episode is missing, e.g. 'legal dispute'.",
    )
    curated_by: str
    audited_by: str | None = Field(default=None)
    audited_at: str | None = Field(default=None)

    @model_validator(mode="before")
    @classmethod
    def _migrate(cls, data: Any) -> Any:
        if isinstance(data, dict):
            return _migrate_provenance(data)
        return data


class SubSeriesFact(BaseModel):
    """A spin-off or sub-series discovered within the discography."""

    label: str
    album_ids: list[str] = Field(default_factory=list)
    reason: str = ""
    curated_by: str
    audited_by: str | None = Field(default=None)
    audited_at: str | None = Field(default=None)

    @model_validator(mode="before")
    @classmethod
    def _migrate(cls, data: Any) -> Any:
        if isinstance(data, dict):
            return _migrate_provenance(data)
        return data


class EraBoundaryProposal(BaseModel):
    """Wire input for proposing an era boundary.

    Enforces non-empty fields so pydantic-ai surfaces validation
    errors back to the agent instead of silently storing garbage.
    """
    label: str = Field(min_length=1, description="Short label, e.g. 'klassik'.")
    release_date_range: str = Field(
        min_length=1,
        description="Year range like '1976-1979' or '2015-'.",
    )


class KnownGapProposal(BaseModel):
    """Wire input for proposing a known gap."""
    number: int = Field(ge=1, description="Missing episode number.")
    reason: str = Field(min_length=1, description="Why it's missing.")


class SubSeriesProposal(BaseModel):
    """Wire input for proposing a sub-series."""
    label: str = Field(min_length=1, description="Short label.")
    album_ids: list[str] = Field(
        default_factory=list,
        description="Album IDs belonging to this sub-series.",
    )
    reason: str = Field(
        default="",
        min_length=1,
        description="Why this is a distinct sub-series.",
    )


class SeriesFacts(BaseModel):
    """Discovered structural facts about a series.

    Curate proposes facts from the discography. Audit (a different
    model family) stamps agreed facts with audited_by + audited_at.
    Unaudited or disagreed facts stay without audited_by; apply only
    writes audited facts to series.yaml.
    """

    era_boundaries: list[EraBoundary] = Field(default_factory=list)
    known_gaps: list[KnownGap] = Field(default_factory=list)
    sub_series: list[SubSeriesFact] = Field(default_factory=list)
