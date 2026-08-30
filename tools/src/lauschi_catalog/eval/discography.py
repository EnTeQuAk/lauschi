"""The set of albums the providers offer for a series.

Replays curate's discovery step (``curate_ops._run_large``, step 1):
every album on every known artist page, deduped by (provider, id).
With a warm provider cache this is a disk read, and it is the same
data the curation runs saw, so an included album outside this set was
not offered by any provider: the model invented it.
"""

from typing import Protocol

from lauschi_catalog.eval.truth import AlbumKey


class _ArtistAlbums(Protocol):
    name: str

    def artist_albums(self, artist_id: str) -> list: ...


def fetch_discography(
    providers: list[_ArtistAlbums], artist_ids: dict[str, list[str]]
) -> frozenset[AlbumKey]:
    """``artist_ids`` maps provider name to the series' known artist ids,
    the shape ``CatalogEntry.all_artist_ids()`` returns."""
    keys: set[AlbumKey] = set()
    for p in providers:
        for aid in artist_ids.get(p.name) or []:
            keys.update(AlbumKey(p.name, a.id) for a in p.artist_albums(aid))
    return frozenset(keys)
