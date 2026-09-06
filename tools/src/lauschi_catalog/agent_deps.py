"""Shared agent dependency base and progress callback type.

All pipeline agents (curate, audit) inherit from AgentDeps so that
shared tools and hooks can access on_progress regardless of which
agent they're attached to. pydantic-ai's AgentDepsT is contravariant,
so FunctionToolset[AgentDeps] is compatible with Agent[CurateDeps]
and Agent[AuditDeps].
"""

from collections.abc import Callable
from dataclasses import dataclass, field

from lauschi_catalog.providers.base import CatalogProvider
from lauschi_catalog.reference import ReferenceIndex

Progress = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


@dataclass
class AgentDeps:
    """Base dependencies shared across all pipeline agents.

    Fields here are used by the shared FunctionToolset in agent_tools.py.
    """

    on_progress: Progress = field(default=_noop)
    providers: list[CatalogProvider] = field(default_factory=list)
    seen_details: dict[str, dict] = field(default_factory=dict)
    #: the public line index; built from the environment on first use
    reference: ReferenceIndex | None = None
    _search_count: int = field(default=0, init=False)
    _fetch_count: int = field(default=0, init=False)
    _detail_count: int = field(default=0, init=False)
    _reference_count: int = field(default=0, init=False)
    _MAX_SEARCHES: int = 3
    _MAX_FETCHES: int = 2
    _MAX_DETAIL_CALLS: int = 40
    _MAX_REFERENCE_CALLS: int = 5
