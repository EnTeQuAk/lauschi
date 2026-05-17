"""Structured series facts discovered by the curation pipeline.

Facts like era_boundaries, known_gaps, and sub_series are discovered by
LLM agents during curation, reviewed, verified, and then frozen into
series.yaml. On subsequent runs (incremental updates), curate loads the
frozen facts as input context and only proposes genuinely new ones.

Each fact carries provenance so we can distinguish documented history
from hallucination that slipped through.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


class EraBoundary(BaseModel):
    """A contiguous time period with a distinct naming convention."""

    label: str = Field(description="Short label, e.g. 'klassik', 'cgi_reboot'.")
    release_date_range: str = Field(
        description="Year range like '1976-1979' or '2015-2018' or '2025-'. "
        "The trailing dash means 'ongoing'.",
    )
    discovered_by: str = Field(default="curate")
    confirmed_by: str | None = Field(default=None)
    confirmed_at: str | None = Field(default=None)
    verify_status: str | None = Field(
        default=None,
        description="'agreed' or 'disagreed' — set by verify per-fact",
    )
    verify_reasoning: str = Field(
        default="",
        description="Why verify disagreed with this specific fact",
    )


class KnownGap(BaseModel):
    """A documented missing episode number, not a curation error."""

    number: int
    reason: str = Field(
        description="Why this episode is missing, e.g. 'legal dispute'.",
    )
    discovered_by: str = Field(default="curate")
    confirmed_by: str | None = Field(default=None)
    confirmed_at: str | None = Field(default=None)
    verify_status: str | None = Field(
        default=None,
        description="'agreed' or 'disagreed' — set by verify per-fact",
    )
    verify_reasoning: str = Field(
        default="",
        description="Why verify disagreed with this specific fact",
    )


class SubSeriesFact(BaseModel):
    """A spin-off or sub-series discovered within the discography."""

    label: str
    album_ids: list[str] = Field(default_factory=list)
    reason: str = ""
    discovered_by: str = Field(default="curate")
    confirmed_by: str | None = Field(default=None)
    confirmed_at: str | None = Field(default=None)
    verify_status: str | None = Field(
        default=None,
        description="'agreed' or 'disagreed' — set by verify per-fact",
    )
    verify_reasoning: str = Field(
        default="",
        description="Why verify disagreed with this specific fact",
    )


class SeriesFacts(BaseModel):
    """Discovered structural facts about a series.

    Curate proposes these from the discography. Review audits them.
    Verify stamps agreed facts with confirmed_by + confirmed_at,
    and flags disagreed ones with verify_status + verify_reasoning
    per-fact. After human review, confirmed facts are frozen into
    series.yaml with provenance.
    """

    era_boundaries: list[EraBoundary] = Field(default_factory=list)
    known_gaps: list[KnownGap] = Field(default_factory=list)
    sub_series: list[SubSeriesFact] = Field(default_factory=list)
