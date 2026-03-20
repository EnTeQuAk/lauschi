import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/providers/provider_type.dart';

/// Wraps AppleMusicApi into the provider-agnostic CatalogSource interface.
class AppleMusicCatalogSource implements CatalogSource {
  AppleMusicCatalogSource(this._api);

  final AppleMusicApi _api;

  @override
  ProviderType get provider => ProviderType.appleMusic;

  @override
  Future<List<CatalogAlbumResult>> searchAlbums(String query) async {
    final results = await _api.searchAlbums(query);
    return results.map(_fromAppleMusic).toList();
  }

  @override
  Future<CatalogAlbumResult?> getAlbum(String albumId) async {
    final album = await _api.getAlbum(albumId);
    return album != null ? _fromAppleMusic(album) : null;
  }

  @override
  Future<List<CatalogTrackResult>> getAlbumTracks(String albumId) async {
    final tracks = await _api.getAlbumTracks(albumId);
    return tracks.map(_trackFromAppleMusic).toList();
  }

  @override
  Future<Map<String, String>> getAlbumCovers(
    List<String> albumIds, {
    int size = 300,
  }) async {
    final covers = <String, String>{};

    if (albumIds.length == 1) {
      // Single ID: use coalescing so concurrent per-card requests
      // get batched into one API call.
      final url = await _api.getAlbumCover(albumIds.first, size: size);
      if (url != null) covers[albumIds.first] = url;
    } else {
      // Multiple IDs: direct batch (used by album list views).
      final albums = await _api.getAlbums(albumIds);
      for (final album in albums) {
        final url = album.artworkUrlForSize(size);
        if (url != null) covers[album.id] = url;
      }
    }

    return covers;
  }

  static CatalogAlbumResult _fromAppleMusic(AppleMusicAlbum album) {
    return CatalogAlbumResult(
      id: album.id,
      name: album.name,
      artistName: album.artistName,
      // Apple Music search doesn't return artist IDs in album attributes.
      // Phase-1 title matching handles most cases. Phase-2 artist ID matching
      // uses IDs from series.yaml (appleMusicArtistIds) instead.
      artistIds: [],
      artworkUrl: album.artworkUrl,
      totalTracks: album.trackCount,
      releaseDate: album.releaseDate,
      provider: ProviderType.appleMusic,
    );
  }

  static CatalogTrackResult _trackFromAppleMusic(AppleMusicTrack track) {
    return CatalogTrackResult(
      id: track.id,
      name: track.name,
      trackNumber: track.trackNumber,
      durationMs: track.durationMs,
      artistName: track.artistName,
    );
  }
}
