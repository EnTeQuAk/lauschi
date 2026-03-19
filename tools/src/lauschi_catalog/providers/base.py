"""Abstract provider interface for catalog operations."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Artist:
    """An artist/series from any provider."""

    id: str
    name: str
    provider: str
    genres: list[str] = field(default_factory=list)
    followers: int = 0


@dataclass(frozen=True)
class Album:
    """An album (Hörspiel episode) from any provider."""

    id: str
    name: str
    provider: str
    total_tracks: int = 0
    release_date: str = ""
    artists: str = ""
    label: str = ""
    tracks: list[Track] = field(default_factory=list)


@dataclass(frozen=True)
class Track:
    """A track within an album."""

    name: str
    duration_ms: int = 0


class CatalogProvider(ABC):
    """Abstract interface for content providers.

    Implementations: SpotifyProvider, AppleMusicProvider.
    Used by discover, curate, and validate commands.
    """

    @property
    @abstractmethod
    def name(self) -> str:
        """Provider identifier (e.g. 'spotify', 'apple_music')."""

    @abstractmethod
    def search_artists(self, query: str, limit: int = 8) -> list[Artist]:
        """Search for artists by name."""

    @abstractmethod
    def artist_albums(self, artist_id: str) -> list[Album]:
        """Fetch all albums for an artist."""

    @abstractmethod
    def album_details(self, album_id: str) -> Album | None:
        """Fetch full album details including tracks."""

    @abstractmethod
    def search_albums(self, query: str, limit: int = 10) -> list[Album]:
        """Search for albums by query."""
