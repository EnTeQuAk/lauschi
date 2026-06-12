"""Shared tools for pipeline agents.

Builds a FunctionToolset with web_search, fetch_page, and
get_album_details. All pipeline agents (curate metadata, batch,
finalize, audit) use these via toolsets=[build_agent_tools()].

The toolset is typed as FunctionToolset[AgentDeps]. Since pydantic-ai's
AgentDepsT is contravariant, this is compatible with Agent[CurateDeps]
and Agent[AuditDeps] where both inherit from AgentDeps.
"""

from __future__ import annotations

from pydantic_ai import FunctionToolset, RunContext
from pydantic_ai.exceptions import ModelRetry

from lauschi_catalog.agent_deps import AgentDeps
from lauschi_catalog.providers._validate import explain_invalid, is_valid_id
from lauschi_catalog.search import brave_search
from lauschi_catalog.search import fetch_page as _fetch_page


def build_agent_tools() -> FunctionToolset[AgentDeps]:
    """Build a toolset with web search, page fetching, and album details."""
    ts: FunctionToolset[AgentDeps] = FunctionToolset()

    @ts.tool
    def web_search(ctx: RunContext[AgentDeps], query: str) -> list[dict]:
        """Search the web for series information (e.g. episode lists, background)."""
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            raise ModelRetry(
                f"Search limit reached ({ctx.deps._MAX_SEARCHES}/{ctx.deps._MAX_SEARCHES}). "
                f"Make your decision using the information you already have."
            )
        ctx.deps._search_count += 1
        return brave_search(query, count=5)

    @ts.tool
    def fetch_page(ctx: RunContext[AgentDeps], url: str) -> str:
        """Fetch a web page for detailed information. Max 4000 chars returned."""
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            raise ModelRetry(
                f"Fetch limit reached ({ctx.deps._MAX_FETCHES}/{ctx.deps._MAX_FETCHES}). "
                f"Make your decision using the information you already have."
            )
        ctx.deps._fetch_count += 1
        return _fetch_page(url, max_chars=4000)

    @ts.tool
    def get_album_details(
        ctx: RunContext[AgentDeps],
        provider: str,
        album_ids: list[str],
    ) -> list[dict]:
        """Fetch full album details (track listing) from a provider."""
        results: list[dict] = []
        invalid = [aid for aid in album_ids if not is_valid_id(provider, aid)]
        valid_ids = [aid for aid in album_ids if is_valid_id(provider, aid)]
        for bad in invalid:
            results.append({"id": bad, "error": explain_invalid(provider, bad)})

        target = next((p for p in ctx.deps.providers if p.name == provider), None)
        if not target:
            return results or []
        for aid in valid_ids:
            key = f"{provider}:{aid}"
            if key in ctx.deps.seen_details:
                results.append(ctx.deps.seen_details[key])
                continue
            album = target.album_details(aid)
            if album:
                detail = {
                    "provider": provider,
                    "id": album.id,
                    "name": album.name,
                    "release_date": album.release_date,
                    "total_tracks": album.total_tracks,
                    "label": album.label,
                    "artists": album.artists,
                    "tracks": [
                        {"name": t.name, "duration_ms": t.duration_ms}
                        for t in album.tracks
                    ],
                }
                ctx.deps.seen_details[key] = detail
                results.append(detail)
        return results

    return ts
