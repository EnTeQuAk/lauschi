"""Catalog data models.

Provider-agnostic series and episode representations.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class ProviderConfig:
    """Per-provider configuration for a series."""

    artist_ids: list[str] = field(default_factory=list)
    album_ids: dict[int, str] = field(default_factory=dict)  # episode -> album ID
    episode_pattern: str | list[str] | None = None  # override


@dataclass
class CatalogEntry:
    """A series in the catalog.

    Provider-agnostic at the top level, with per-provider data in the
    providers dict.
    """

    id: str
    title: str
    keywords: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)
    episode_pattern: str | list[str] | None = None
    cover_url: str | None = None
    providers: dict[str, ProviderConfig] = field(default_factory=dict)

    def artist_ids(self, provider: str) -> list[str]:
        """Get artist IDs for a specific provider."""
        cfg = self.providers.get(provider)
        return cfg.artist_ids if cfg else []

    def all_artist_ids(self) -> dict[str, list[str]]:
        """Get artist IDs for all providers."""
        return {
            name: cfg.artist_ids
            for name, cfg in self.providers.items()
            if cfg.artist_ids
        }

    def effective_pattern(self, provider: str | None = None) -> str | list[str] | None:
        """Get the effective episode pattern, with optional per-provider override."""
        if provider:
            cfg = self.providers.get(provider)
            if cfg and cfg.episode_pattern:
                return cfg.episode_pattern
        return self.episode_pattern
