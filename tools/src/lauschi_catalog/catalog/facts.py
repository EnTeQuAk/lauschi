"""Structured series facts discovered by the curation pipeline.

Facts like era_boundaries, known_gaps, and sub_series are discovered by
LLM agents during curation, audited by a second model (4-eye principle),
and then frozen into series.yaml. On subsequent runs (incremental
updates), curate loads the frozen facts as input context and only
proposes genuinely new ones.

Each fact carries provenance: curated_by/curated_at record who created
it, audited_by/audited_at record who last reviewed it.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


import re as _re


class _FactProvenance(BaseModel):
    """Shared provenance fields for all fact types."""

    curated_by: str = "unknown"
    curated_at: str | None = Field(default=None)
    audited_by: str | None = Field(default=None)
    audited_at: str | None = Field(default=None)


class EraBoundary(_FactProvenance):
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


class KnownGap(_FactProvenance):
    """A documented missing episode number, not a curation error."""

    number: int
    reason: str = Field(
        description="Why this episode is missing, e.g. 'legal dispute'.",
    )


class SubSeriesFact(_FactProvenance):
    """A spin-off or sub-series discovered within the discography."""

    label: str
    album_ids: list[str] = Field(default_factory=list)
    reason: str = ""


def fact_provenance(*, by: str, at: str, audited: bool = False) -> dict:
    """Build the provenance dict to spread onto a proposal's model_dump().

    ``by`` is the model or agent name. ``at`` is an ISO timestamp.
    When ``audited`` is True, the same values are set for the audit
    fields too (used when audit replaces or merges facts).
    """
    d: dict = {"curated_by": by, "curated_at": at}
    if audited:
        d["audited_by"] = by
        d["audited_at"] = at
    return d


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
        description=(
            "Album IDs belonging to this sub-series. "
            "Use search_included_albums to find them by title keyword."
        ),
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
