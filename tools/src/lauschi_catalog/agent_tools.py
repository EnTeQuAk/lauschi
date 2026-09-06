"""Shared tools for pipeline agents.

Builds a FunctionToolset with web_search, fetch_page, get_album_details
and lookup_reference_lines. All pipeline agents (curate metadata, batch,
finalize, audit) use these via toolsets=[build_agent_tools()].

The toolset is typed as FunctionToolset[AgentDeps]. Since pydantic-ai's
AgentDepsT is contravariant, this is compatible with Agent[CurateDeps]
and Agent[AuditDeps] where both inherit from AgentDeps.
"""

from pydantic_ai import FunctionToolset, RunContext

from lauschi_catalog.agent_deps import AgentDeps
from lauschi_catalog.providers._validate import explain_invalid, is_valid_id
from lauschi_catalog.reference import ReferenceIndex
from lauschi_catalog.search import brave_search
from lauschi_catalog.search import fetch_page as _fetch_page


def _limit(what: str, cap: int) -> str:
    """The message a tool returns once its budget is spent.

    Returned as a result, not raised as ModelRetry: a retry counts
    against pydantic-ai's per-tool cap and the third call past the
    budget would end the whole run instead of the model's fetching.
    """
    return f"{what} limit reached ({cap}). Decide with what you have."


def build_agent_tools() -> FunctionToolset[AgentDeps]:
    """Build a toolset with web search, page fetching, and album details."""
    ts: FunctionToolset[AgentDeps] = FunctionToolset()

    @ts.tool
    def web_search(ctx: RunContext[AgentDeps], query: str) -> list[dict]:
        """Search the web for series information (e.g. episode lists, background)."""
        if ctx.deps._search_count >= ctx.deps._MAX_SEARCHES:
            return [{"error": _limit("Search", ctx.deps._MAX_SEARCHES)}]
        ctx.deps._search_count += 1
        return brave_search(query, count=5)

    @ts.tool
    def fetch_page(ctx: RunContext[AgentDeps], url: str) -> str:
        """Fetch a web page for detailed information. Max 4000 chars returned."""
        if ctx.deps._fetch_count >= ctx.deps._MAX_FETCHES:
            return _limit("Fetch", ctx.deps._MAX_FETCHES)
        ctx.deps._fetch_count += 1
        return _fetch_page(url, max_chars=4000)

    @ts.tool
    def get_album_details(
        ctx: RunContext[AgentDeps],
        provider: str,
        album_ids: list[str],
    ) -> list[dict]:
        """Fetch full album details (track listing) from a provider."""
        if ctx.deps._detail_count >= ctx.deps._MAX_DETAIL_CALLS:
            return [{"error": _limit("Detail fetch", ctx.deps._MAX_DETAIL_CALLS)}]
        ctx.deps._detail_count += 1
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

    @ts.tool
    def lookup_reference_lines(ctx: RunContext[AgentDeps], series_name: str) -> dict:
        """Look a brand up in the public line index: its lines, each with
        the episode titles that belong to it.

        Use it to place an album in a line and for the names of a
        brand's lines. It carries no episode numbers on purpose: numbers
        come from the provider metadata, never from here. The index
        lags behind new releases and lists only licensed titles: an
        absent title proves nothing.
        """
        if ctx.deps._reference_count >= ctx.deps._MAX_REFERENCE_CALLS:
            return {"error": _limit("Reference lookup", ctx.deps._MAX_REFERENCE_CALLS)}
        ctx.deps._reference_count += 1
        if ctx.deps.reference is None:
            ctx.deps.reference = ReferenceIndex()
        index = ctx.deps.reference
        if not index.configured:
            return {
                "error": "The public line index is not configured (REFERENCE_INDEX_URL)."
            }
        found = index.lines_for(series_name)
        if found is None:
            return {"error": f"No series named {series_name!r} in the index."}
        ctx.deps.on_progress(
            f"  lookup_reference_lines({series_name!r}) -> {found.name!r}, "
            f"{len(found.lines)} line(s)"
        )
        return {
            "series": found.name,
            "lines": [
                {"name": line.name, "titles": [e.title for e in line.episodes]}
                for line in found.lines
            ],
        }

    return ts
