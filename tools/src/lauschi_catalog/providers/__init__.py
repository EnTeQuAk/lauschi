"""Content providers for catalog discovery and validation."""

from lauschi_catalog.providers.base import (
    Album,
    AlbumBatch,
    Artist,
    CatalogProvider,
)

__all__ = ["Album", "AlbumBatch", "Artist", "CatalogProvider"]
