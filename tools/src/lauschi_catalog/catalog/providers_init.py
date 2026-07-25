"""Shared provider initialization.

Initializes available catalog providers, skipping ones missing
credentials. Returns the providers that loaded successfully along
with warnings for any that failed.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from lauschi_catalog.providers import CatalogProvider


@dataclass
class ProvidersResult:
    providers: list[CatalogProvider] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def init_providers(
    which: str = "all",
    *,
    use_cache: bool = True,
) -> ProvidersResult:
    """Initialize catalog providers, skipping unavailable ones.

    Args:
        which: "spotify", "apple_music", or "all"
        use_cache: False bypasses the disk cache. Drift detection needs
            this: comparing our snapshot against our own cached copy of
            it would verify nothing.
    """
    result = ProvidersResult()

    if which in ("spotify", "all"):
        try:
            from lauschi_catalog.providers.spotify import SpotifyProvider

            result.providers.append(SpotifyProvider(use_cache=use_cache))
        except (Exception, SystemExit):
            result.warnings.append("Spotify credentials not set, skipping")

    if which in ("apple_music", "all"):
        try:
            from lauschi_catalog.providers.apple_music import AppleMusicProvider

            result.providers.append(AppleMusicProvider(use_cache=use_cache))
        except (Exception, SystemExit):
            result.warnings.append("Apple Music key not found, skipping")

    return result
