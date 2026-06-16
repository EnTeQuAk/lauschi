"""Prompt loader for curate and audit agents.

Loads skill-style prompt documents from disk and assembles per-phase,
per-content-type system prompts. Pure function: no global state, no
fs caching. Cheap enough to call per-agent-build.
"""

from __future__ import annotations

import importlib.resources
from typing import Literal

ContentType = Literal["hoerspiel", "music", "audiobook"]
Phase = Literal["metadata", "batch", "finalize"]

_PROMPT_PACKAGE = "lauschi_catalog.prompts.curate"


def _read_resource(rel_path: str) -> str:
    """Read a text file from the prompt package."""
    # Use files() API for Python 3.9+ compatibility
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
      1. SKILL.md — universal principles (provider rules, ID handling,
         output schema, content-type purity)
      2. references/<content_type>.md — type-specific failure taxonomy
      3. references/era_detection.md (if discography_span_years >= 10)
      4. references/split_guidelines.md (batch + finalize phases)
      5. PHASE_<phase>.md — phase-specific reminders + output schema pointer

    Args:
        phase: Which pipeline phase (metadata, batch, finalize)
        content_type: Which content type (hoerspiel, music, audiobook)
        discography_span_years: If >= 10, loads era detection reference

    Returns:
        Fully assembled system prompt string.
    """
    parts: list[str] = []

    # 1. Base skill doc (universal principles)
    parts.append(_read_resource("SKILL.md"))

    # 2. Content-type reference doc
    type_map = {
        "hoerspiel": "references/hoerspiel.md",
        "music": "references/music.md",
        "audiobook": "references/audiobook.md",
    }
    if content_type in type_map:
        parts.append(_read_resource(type_map[content_type]))

    # 3. Cross-cutting references
    if discography_span_years is not None and discography_span_years >= 10:
        parts.append(_read_resource("references/era_detection.md"))
    if phase in ("batch", "finalize"):
        parts.append(_read_resource("references/split_guidelines.md"))

    # 4. Phase suffix
    phase_file = f"PHASE_{phase}.md"
    parts.append(_read_resource(phase_file))

    # 5. Date anchor: models date-reason from their training cutoff
    # without it (release dates, "future" releases, era recency).
    parts.append(current_date_line())

    return "\n\n".join(parts)


def current_date_line() -> str:
    """Return a 'Today is YYYY-MM-DD.' line for prompt assembly."""
    from datetime import date

    return f"Today is {date.today().isoformat()}."
