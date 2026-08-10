import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';

/// Wraps SpotifyApi into the provider-agnostic CatalogSource interface.
class SpotifyCatalogSource implements CatalogSource {
  SpotifyCatalogSource(this._api);

  final SpotifyApi _api;

  @override
  ProviderType get provider => ProviderType.spotify;

  @override
  Future<List<CatalogAlbumResult>> searchAlbums(String query) async {
    final result = await _api.searchAlbums(query);
    return result.albums.map(_fromSpotify).toList();
  }

  @override
  Future<CatalogAlbumResult?> getAlbum(String albumId) async {
    final album = await _api.getAlbum(albumId);
    return album != null ? _fromSpotify(album) : null;
  }

  @override
  Future<List<CatalogTrackResult>> getAlbumTracks(String albumId) async {
    // Paged endpoint, not the embedded track list on the album detail:
    // that list is capped at 50 tracks and would silently truncate
    // Kinderlieder compilations and box sets.
    final tracks = await _api.getAlbumTracks(albumId);
    return tracks.map(_trackFromSpotify).toList();
  }

  @override
  Future<Map<String, String>> getAlbumCovers(
    List<String> albumIds, {
    int size = 300,
  }) async {
    final covers = <String, String>{};
    // Spotify batch endpoint supports max 20 IDs per request.
    for (var i = 0; i < albumIds.length; i += 20) {
      final batch = albumIds.sublist(
        i,
        (i + 20).clamp(0, albumIds.length),
      );
      try {
        final albums = await _api.getAlbums(batch);
        for (final album in albums) {
          final url = _fromSpotify(album).artworkUrlForSize(size);
          if (url != null) {
            covers[album.id] = url;
          }
        }
        // A TypeError from an unexpected response shape is an Error,
        // not an Exception, and must also only fail its own batch.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {
        // Skip failed batches, show placeholders for those albums.
      }
    }
    return covers;
  }

  @override
  void cancelCover(String albumId) {
    // Spotify uses direct batch fetches, no coalescing to cancel.
  }

  static CatalogAlbumResult _fromSpotify(SpotifyAlbum album) {
    return CatalogAlbumResult(
      id: album.id,
      name: album.name,
      artistName: album.artists.join(', '),
      artistIds: album.artistIds,
      artworkUrl: album.imageUrl,
      artworkRenditions: album.images,
      totalTracks: album.totalTracks,
      releaseDate: album.releaseDate,
      provider: ProviderType.spotify,
    );
  }

  static CatalogTrackResult _trackFromSpotify(SpotifyTrack track) {
    return CatalogTrackResult(
      id: track.id,
      name: track.name,
      durationMs: track.durationMs,
      artistName: track.artistNames,
    );
  }
}
