import 'package:lauschi/core/providers/provider_type.dart';

/// Resolve artwork [renditions] to a URL at [size] px: the smallest
/// rendition at least [size] wide, else [fallbackUrl] with Apple Music
/// `{w}x{h}` templates filled, else null.
///
/// Works straight off a provider's rendition list, so cover-batch
/// callers do not build a throwaway [CatalogAlbumResult] per album.
String? resolveArtworkUrl(
  List<({String? url, int? width})> renditions,
  String? fallbackUrl,
  int size,
) {
  String? best;
  int? bestWidth;
  for (final rendition in renditions) {
    final width = rendition.width;
    if (rendition.url == null || width == null) continue;
    if (width >= size && (bestWidth == null || width < bestWidth)) {
      best = rendition.url;
      bestWidth = width;
    }
  }
  if (best != null) return best;
  if (fallbackUrl == null) return null;
  return fallbackUrl.replaceAll('{w}', '$size').replaceAll('{h}', '$size');
}

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
    this.artworkRenditions = const [],
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

  /// Fixed-size artwork renditions, largest first, for providers that
  /// publish discrete sizes instead of a template URL (Spotify:
  /// 640/300/64 px). Empty when [artworkUrl] alone applies.
  final List<({String? url, int? width})> artworkRenditions;

  final int totalTracks;
  final String? releaseDate;
  final ProviderType provider;

  /// Canonical provider URI for DB storage.
  /// Exhaustive: add new providers here when extending ProviderType.
  String get providerUri => provider.albumUri(id);

  /// Resolve artwork to a specific pixel size, so a 300px tile does
  /// not download 640px art.
  ///
  /// Picks the smallest rendition still at least [size] wide when
  /// renditions exist; otherwise fills Apple Music `{w}x{h}` templates
  /// and passes other URLs through unchanged.
  String? artworkUrlForSize(int size) =>
      resolveArtworkUrl(artworkRenditions, artworkUrl, size);
}

/// Track within a catalog album, in album order.
///
/// Carries no provider track number: providers number tracks per disc,
/// so multi-disc box sets would show 1..12 twice. Display code numbers
/// tracks by list position instead.
class CatalogTrackResult {
  const CatalogTrackResult({
    required this.id,
    required this.name,
    required this.durationMs,
    this.artistName,
  });

  final String id;
  final String name;
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

  /// Cancel a pending cover request for an album.
  ///
  /// Called when a card scrolls off screen before its cover loaded.
  /// Removes the ID from pending batches so it's not fetched.
  /// No-op if the request already completed or isn't pending.
  void cancelCover(String albumId) {}
}
