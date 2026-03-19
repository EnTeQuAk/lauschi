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
    final album = await _api.getAlbum(albumId);
    if (album?.tracks == null) return [];
    return album!.tracks!.map(_trackFromSpotify).toList();
  }

  static CatalogAlbumResult _fromSpotify(SpotifyAlbum album) {
    return CatalogAlbumResult(
      id: album.id,
      name: album.name,
      artistName: album.artists.join(', '),
      artistIds: album.artistIds,
      artworkUrl: album.imageUrl,
      totalTracks: album.totalTracks,
      releaseDate: album.releaseDate,
      provider: ProviderType.spotify,
    );
  }

  static CatalogTrackResult _trackFromSpotify(SpotifyTrack track) {
    return CatalogTrackResult(
      id: track.id,
      name: track.name,
      trackNumber: track.trackNumber,
      durationMs: track.durationMs,
      artistName: track.artistNames,
    );
  }
}
