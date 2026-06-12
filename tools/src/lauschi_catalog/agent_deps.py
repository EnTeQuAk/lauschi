"""Shared agent dependency base and progress callback type.

All pipeline agents (curate, audit) inherit from AgentDeps so that
shared tools and hooks can access on_progress regardless of which
agent they're attached to. pydantic-ai's RunContext is covariant
in its deps type, so RunContext[CurateDeps] satisfies
RunContext[AgentDeps].
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


@dataclass
class AgentDeps:
    """Base dependencies shared across all pipeline agents."""

    on_progress: Progress = field(default=_noop)
