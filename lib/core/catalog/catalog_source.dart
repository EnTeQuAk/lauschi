import 'package:lauschi/core/providers/provider_type.dart';

/// Album from any catalog search (Spotify, Apple Music, etc.).
///
/// Provider-agnostic representation used by the browse UI and catalog
/// matching. Wraps provider-specific models (SpotifyAlbum, AppleMusicAlbum)
/// into a common shape.
class CatalogAlbumResult {
  CatalogAlbumResult({
    required this.id,
    required this.name,
    required this.artistName,
    required this.artistIds,
    required this.provider,
    this.artworkUrl,
    this.totalTracks = 0,
    this.releaseDate,
  });

  /// Provider-specific album ID.
  final String id;

  /// Album title (e.g. "Folge 42: Der Fluch des Pharao").
  final String name;

  /// Primary artist display name.
  final String artistName;

  /// Provider-specific artist IDs for catalog phase-2 matching.
  final List<String> artistIds;

  /// Artwork URL. For Apple Music, contains `{w}x{h}` template.
  final String? artworkUrl;

  final int totalTracks;
  final String? releaseDate;
  final ProviderType provider;

  /// Canonical provider URI for DB storage.
  /// Exhaustive: add new providers here when extending ProviderType.
  String get providerUri => switch (provider) {
    ProviderType.spotify => 'spotify:album:$id',
    ProviderType.appleMusic => 'apple_music:album:$id',
    ProviderType.ardAudiothek => 'ard:album:$id',
    ProviderType.tidal => 'tidal:album:$id',
  };

  /// Resolve artwork URL to a specific pixel size.
  /// Handles Apple Music `{w}x{h}` templates and passes through
  /// other URLs unchanged.
  String? artworkUrlForSize(int size) {
    if (artworkUrl == null) return null;
    return artworkUrl!.replaceAll('{w}', '$size').replaceAll('{h}', '$size');
  }
}

/// Track within a catalog album.
class CatalogTrackResult {
  const CatalogTrackResult({
    required this.id,
    required this.name,
    required this.trackNumber,
    required this.durationMs,
    this.artistName,
  });

  final String id;
  final String name;
  final int trackNumber;
  final int durationMs;
  final String? artistName;
}

/// Provider-agnostic catalog search and metadata retrieval.
///
/// Implemented by SpotifyCatalogSource and AppleMusicCatalogSource.
/// The browse screen takes a CatalogSource and doesn't know which
/// provider it's talking to.
abstract class CatalogSource {
  ProviderType get provider;

  /// Search albums by query string.
  Future<List<CatalogAlbumResult>> searchAlbums(String query);

  /// Fetch full album details (may include tracks).
  Future<CatalogAlbumResult?> getAlbum(String albumId);

  /// Fetch tracks for an album.
  Future<List<CatalogTrackResult>> getAlbumTracks(String albumId);

  /// Batch-fetch cover image URLs for albums.
  ///
  /// Returns a map of albumId → artwork URL. Albums that fail to load
  /// or have no artwork are omitted from the result.
  /// Implementations should batch API calls where possible.
  Future<Map<String, String>> getAlbumCovers(
    List<String> albumIds, {
    int size = 300,
  });
}
