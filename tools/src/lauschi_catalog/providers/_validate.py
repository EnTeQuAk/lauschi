"""Provider id format checks.

Several pipeline failures came from the small-flow agent confusing
provider+id pairs (e.g., calling apple_music with a Spotify-format
22-char base62 id, then 404'ing). Validating IDs at the tool
boundary turns those into clean error returns the agent can recover
from, before the HTTP request is even made.

Spotify IDs: 22-character base62 (a-z, A-Z, 0-9). Documented at
https://developer.spotify.com/documentation/web-api/concepts/spotify-uris-ids
Apple Music IDs: all-digit numeric strings (no fixed length, but
always digits). Observed from the catalog: 9-12 digits typical,
older IDs as short as 8.
"""

from __future__ import annotations

import re

_SPOTIFY_ID = re.compile(r"^[A-Za-z0-9]{22}$")
_APPLE_MUSIC_ID = re.compile(r"^\d+$")


def is_valid_id(provider_name: str, artist_or_album_id: str) -> bool:
    """True when the id matches the format the named provider expects.

    Used by tool wrappers to reject obvious provider/id mismatches
    before they hit the API. Conservative — unknown providers
    return True so this never blocks a future provider's calls.
    """
    if not isinstance(artist_or_album_id, str) or not artist_or_album_id:
        return False
    if provider_name == "spotify":
        return bool(_SPOTIFY_ID.match(artist_or_album_id))
    if provider_name == "apple_music":
        return bool(_APPLE_MUSIC_ID.match(artist_or_album_id))
    return True


def explain_invalid(provider_name: str, artist_or_album_id: str) -> str:
    """Return a short error message explaining why the id is invalid.

    Designed to be returned to the agent as a tool-call response so
    the model has actionable guidance instead of a raw 4xx surface.
    """
    if provider_name == "spotify":
        return (
            f"id {artist_or_album_id!r} is not a valid Spotify id "
            f"(must be 22 base62 characters). If this id came from "
            f"Apple Music, call the tool with provider='apple_music'."
        )
    if provider_name == "apple_music":
        return (
            f"id {artist_or_album_id!r} is not a valid Apple Music id "
            f"(must be all digits). If this id came from Spotify, "
            f"call the tool with provider='spotify'."
        )
    return f"id {artist_or_album_id!r} is not valid for provider {provider_name!r}"
