"""Shared builders for test data.

One place for the shapes every test reaches for: a curation album
record, a discovered provider album, a curation, a catalog entry, an
album decision. Each takes keyword overrides and fills the rest with a
plain default, so a test states only what it is about.
"""

from typing import Any

from lauschi_catalog.catalog.curate_ops import AlbumDecision
from lauschi_catalog.catalog.models import CatalogEntry, ProviderConfig


def album_record(
    album_id: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    exclude_reason: str | None = None,
    title: str | None = None,
    **extra: Any,
) -> dict[str, Any]:
    """An album as stored in a curation JSON."""
    record: dict[str, Any] = {
        "album_id": album_id,
        "provider": provider,
        "include": include,
        "episode_num": episode_num,
        "title": title if title is not None else album_id,
    }
    if exclude_reason is not None:
        record["exclude_reason"] = exclude_reason
    record.update(extra)
    return record


def discovered_album(
    provider: str, album_id: str, name: str = "Album"
) -> dict[str, str]:
    """An album as the discovery step hands it to the batch phase."""
    return {"provider": provider, "id": album_id, "name": name}


def curation(
    *,
    series_id: str = "s",
    title: str = "S",
    albums: list[dict[str, Any]] | tuple[dict[str, Any], ...] = (),
    **extra: Any,
) -> dict[str, Any]:
    """A curation dict with the keys every reader expects."""
    data: dict[str, Any] = {"id": series_id, "title": title, "albums": list(albums)}
    data.update(extra)
    return data


def entry(
    series_id: str,
    title: str | None = None,
    *,
    spotify: tuple[str, ...] | list[str] = (),
    apple: tuple[str, ...] | list[str] = (),
    split_from: str | None = None,
    **kw: Any,
) -> CatalogEntry:
    """A CatalogEntry with artist ids per provider."""
    providers: dict[str, ProviderConfig] = {}
    if spotify:
        providers["spotify"] = ProviderConfig(artist_ids=list(spotify))
    if apple:
        providers["apple_music"] = ProviderConfig(artist_ids=list(apple))
    return CatalogEntry(
        id=series_id,
        title=title if title is not None else series_id,
        split_from=split_from,
        providers=providers,
        **kw,
    )


def decision(
    album_id: str,
    *,
    provider: str = "spotify",
    include: bool = True,
    episode_num: int | None = None,
    title: str | None = None,
    release_date: str | None = None,
    exclude_reason: str | None = None,
    confidence: str = "high",
) -> AlbumDecision:
    """An AlbumDecision as the batch phase returns it."""
    return AlbumDecision(
        album_id=album_id,
        provider=provider,
        include=include,
        episode_num=episode_num,
        title=title if title is not None else album_id,
        release_date=release_date,
        exclude_reason=exclude_reason,
        confidence=confidence,
    )
