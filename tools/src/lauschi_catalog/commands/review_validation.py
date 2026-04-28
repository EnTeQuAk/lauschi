"""Validation helpers for the review agent's mutating tools.

Kept separate from review.py so they import cleanly without pydantic-ai
and can be unit-tested without spinning up an agent.
"""

from __future__ import annotations

from typing import Protocol
from urllib.parse import urlparse


class _ResearchCounters(Protocol):
    """Subset of review.Deps that this module needs."""

    _search_count: int
    _fetch_count: int


# Provider domains can't serve as evidence for adding the same album:
# pointing at the album's own Spotify or Apple Music page is circular.
# Evidence has to come from an external source — hoerspiele.de,
# Wikipedia, the publisher's site, etc.
_PROVIDER_DOMAINS = frozenset({
    "open.spotify.com",
    "spotify.com",
    "music.apple.com",
    "itunes.apple.com",
})


def validate_add_evidence(
    deps: _ResearchCounters,
    evidence_url: str,
) -> str | None:
    """Gate the add_album tool: refuse adds the agent can't justify.

    Returns ``None`` if the add may proceed, or a human-readable error
    message describing why it can't. The agent receives this string back
    as the tool result and can adjust on the next turn.

    Rules:
    1. ``evidence_url`` must be a non-empty http(s) URL.
    2. The URL must NOT come from a streaming-provider domain (citing
       the album's own Spotify/Apple Music page would be circular).
    3. The agent must have used ``web_search`` or ``fetch_page`` at least
       once before calling add_album, so the URL is plausibly grounded
       in real search results rather than hallucinated.
    """
    if not evidence_url:
        return (
            "add_album requires evidence_url. Pass the URL of a search "
            "result or page that confirms this album exists for the series."
        )
    if not evidence_url.startswith(("http://", "https://")):
        return f"evidence_url must be an http(s) URL, got {evidence_url!r}."
    domain = urlparse(evidence_url).netloc.lower()
    # Strip ``www.`` so ``www.spotify.com`` matches.
    domain = domain.removeprefix("www.")
    if domain in _PROVIDER_DOMAINS:
        return (
            f"evidence_url must come from an external source "
            f"(hoerspiele.de, Wikipedia, publisher site), not {domain}. "
            "The provider's own album page is not independent evidence."
        )
    if deps._search_count + deps._fetch_count == 0:
        return (
            "Use web_search or fetch_page first to find evidence; "
            "add_album cannot be called without prior research."
        )
    return None
