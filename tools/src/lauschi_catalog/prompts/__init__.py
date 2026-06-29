"""Prompt loader for catalog pipeline agents.

Loads skill-style prompt documents from disk and assembles per-phase,
per-content-type system prompts. Pure function: no global state, no
fs caching. Cheap enough to call per-agent-build.
"""

from __future__ import annotations

import importlib.resources
from typing import Literal

ContentType = Literal["hoerspiel", "music", "audiobook"]
Phase = Literal["metadata", "batch", "finalize", "audit"]

_PROMPT_PACKAGE = "lauschi_catalog.prompts.curate"

_TYPE_REFS = {
    "hoerspiel": "references/hoerspiel.md",
    "music": "references/music.md",
    "audiobook": "references/audiobook.md",
}

_SPLIT_PHASES: set[Phase] = {"batch", "finalize"}


def _read_resource(rel_path: str) -> str:
    """Read a text file from the prompt package."""
    ref = importlib.resources.files(_PROMPT_PACKAGE) / rel_path
    return ref.read_text(encoding="utf-8")


def load_curate_skill(
    *,
    phase: Phase,
    content_type: ContentType = "hoerspiel",
    discography_span_years: int | None = None,
) -> str:
    """Assemble the system prompt for a given phase + content type.

    Composition (in order):
      1. SKILL.md — universal principles (content-type purity,
         cross-provider consistency, inclusion bias, confidence)
      2. references/<content_type>.md — type-specific failure taxonomy
      3. references/era_detection.md (if discography_span_years >= 10)
      4. references/split_guidelines.md (batch, finalize, audit phases)
      5. PHASE_<phase>.md — phase-specific workflow and output contract
      6. Date anchor
    """
    parts: list[str] = []

    parts.append(_read_resource("SKILL.md"))

    if content_type in _TYPE_REFS:
        parts.append(_read_resource(_TYPE_REFS[content_type]))

    if discography_span_years is not None and discography_span_years >= 10 and content_type == "hoerspiel":
        parts.append(_read_resource("references/era_detection.md"))
    if phase in _SPLIT_PHASES:
        parts.append(_read_resource("references/split_guidelines.md"))

    parts.append(_read_resource(f"PHASE_{phase}.md"))
    parts.append(current_date_line())

    return "\n\n".join(parts)


def current_date_line() -> str:
    """Return a 'Today is YYYY-MM-DD.' line for prompt assembly."""
    from datetime import date

    return f"Today is {date.today().isoformat()}."
