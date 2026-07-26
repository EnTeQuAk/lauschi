import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:yaml/yaml.dart';

const _tag = 'CatalogService';

/// Content type for catalog entries and tiles.
enum ContentType {
  hoerspiel('hoerspiel'),
  music('music');

  const ContentType(this.value);

  final String value;

  /// Parse from a string (e.g. from YAML or DB). Defaults to hoerspiel.
  static ContentType fromString(String? value) => switch (value) {
    'music' => ContentType.music,
    'audiobook' || 'hoerspiel' || null => ContentType.hoerspiel,
    _ => ContentType.hoerspiel,
  };
}

/// A pre-validated album entry in the catalog.
///
/// Provider-agnostic: stores the album ID and which provider it belongs to.
/// The same series may have albums from multiple providers (Spotify, Apple Music).
class CatalogAlbum {
  const CatalogAlbum({
    required this.id,
    required this.provider,
    required this.title,
    this.episode,
  });

  /// Provider-specific album ID.
  final String id;

  /// Which provider this album belongs to.
  final ProviderType provider;

  final String title;
  final int? episode;

  /// Full provider URI for DB storage (e.g. 'spotify:album:abc123').
  String get uri => provider.albumUri(id);

  /// Backward compat: returns [id] when provider is Spotify.
  @Deprecated('Use id and provider instead')
  String get spotifyId => id;
}

/// A single known Hörspiel series from the bundled catalog.
class CatalogSeries {
  const CatalogSeries({
    required this.id,
    required this.title,
    required this.aliases,
    required this.spotifyArtistIds,
    this.appleMusicArtistIds = const [],
    this.coverUrl,
    this.albums = const [],
    this.appleMusicAlbums = const [],
    this.contentType = ContentType.hoerspiel,
  });

  final String id;
  final String title;

  /// Content type: hoerspiel (default) or music.
  /// Used to filter the curated grid between Hörspiele and Musik tabs.
  final ContentType contentType;

  /// Whether this is a music artist (not a Hörspiel series).
  bool get isMusic => contentType == ContentType.music;
  final List<String> aliases;

  /// Spotify artist IDs whose albums belong to this series.
  /// Used by tile-edit and detail screens (not by the matcher).
  final List<String> spotifyArtistIds;

  /// Apple Music artist IDs whose albums belong to this series.
  /// Used by tile-edit and detail screens (not by the matcher).
  final List<String> appleMusicArtistIds;

  /// Curated cover image URL for this series.
  /// Typically the Spotify artist image or a hand-picked cover.
  final String? coverUrl;

  /// Pre-validated Spotify album list with episode numbers.
  /// Empty for series that haven't been fully curated yet.
  final List<CatalogAlbum> albums;

  /// Pre-validated Apple Music album list with episode numbers.
  final List<CatalogAlbum> appleMusicAlbums;

  /// Whether this series has curated albums for any provider.
  bool get hasCuratedAlbums => albums.isNotEmpty || appleMusicAlbums.isNotEmpty;

  /// Get curated albums for a specific provider.
  List<CatalogAlbum> albumsForProvider(ProviderType provider) =>
      switch (provider) {
        ProviderType.spotify => albums,
        ProviderType.appleMusic => appleMusicAlbums,
        _ => const [],
      };

  /// Whether this series has curated albums for a specific provider.
  bool hasCuratedAlbumsFor(ProviderType provider) =>
      albumsForProvider(provider).isNotEmpty;
}

/// Result when a catalog match is found.
class CatalogMatch {
  const CatalogMatch({required this.series, this.episodeNumber});

  final CatalogSeries series;

  /// Extracted episode number, or null if title format didn't match.
  final int? episodeNumber;
}

/// Loads and provides the DACH Hörspiel series catalog from bundled assets.
///
/// The catalog is heuristic — used to suggest group assignments when adding
/// cards. It is not a sync mechanism; episode lists may be incomplete.
class CatalogService {
  CatalogService._(this._series) : _albumIndex = _buildAlbumIndex(_series);

  final List<CatalogSeries> _series;

  /// Fast lookup from a provider+album_id to its owning series and the
  /// curated album record. Built once at load time from every series's
  /// curated album list (both Spotify and Apple Music).
  /// Key format: ``'${provider.value}:${album_id}'``.
  ///
  /// This is the backbone of Phase 0 matching — when a discovered album's
  /// id is already in the catalog, the lookup is O(1) and 100% precise.
  /// Carrying the album (not just the series) is what lets [match] return
  /// the curated episode number instead of re-deriving one.
  final Map<String, _IndexedAlbum> _albumIndex;

  static Map<String, _IndexedAlbum> _buildAlbumIndex(
    List<CatalogSeries> series,
  ) {
    final out = <String, _IndexedAlbum>{};
    for (final s in series) {
      for (final a in s.albums) {
        out['${a.provider.value}:${a.id}'] = _IndexedAlbum(s, a);
      }
      for (final a in s.appleMusicAlbums) {
        out['${a.provider.value}:${a.id}'] = _IndexedAlbum(s, a);
      }
    }
    return out;
  }

  /// Number of known series.
  int get seriesCount => _series.length;

  /// Number of catalog-known albums across all series and providers.
  int get albumCount => _albumIndex.length;

  /// Load the catalog from bundled YAML asset.
  static Future<CatalogService> load() async {
    final raw = await rootBundle.loadString('assets/catalog/series.yaml');
    final doc = loadYaml(raw) as YamlMap;
    final seriesList = doc['series'] as YamlList;

    final parsed = <CatalogSeries>[];
    for (final entry in seriesList) {
      final map = entry as YamlMap;

      final aliasesRaw = map['aliases'] as YamlList?;
      final aliases =
          aliasesRaw == null
              ? <String>[]
              : aliasesRaw.map<String>((a) => a as String).toList();

      // Parse per-provider identifiers from the `providers:` map.
      final providersMap = map['providers'] as YamlMap?;
      final spotifyMap = providersMap?['spotify'] as YamlMap?;

      final artistIdsRaw = spotifyMap?['artist_ids'] as YamlList?;
      final artistIds =
          artistIdsRaw == null
              ? <String>[]
              : artistIdsRaw.map<String>((a) => a as String).toList();

      final albumsRaw = spotifyMap?['albums'] as YamlList?;
      final albums =
          albumsRaw == null
              ? <CatalogAlbum>[]
              : albumsRaw.map<CatalogAlbum>((a) {
                final aMap = a as YamlMap;
                return CatalogAlbum(
                  id: aMap['id'] as String,
                  provider: ProviderType.spotify,
                  title: aMap['title'] as String,
                  episode: aMap['episode'] as int?,
                );
              }).toList();

      // Apple Music provider data
      final appleMusicMap = providersMap?['apple_music'] as YamlMap?;

      final amAlbumsRaw = appleMusicMap?['albums'] as YamlList?;
      // Apple Music IDs may parse as int. toString() handles both.
      final amAlbums =
          amAlbumsRaw == null
              ? <CatalogAlbum>[]
              : amAlbumsRaw.map<CatalogAlbum>((a) {
                final aMap = a as YamlMap;
                return CatalogAlbum(
                  id: aMap['id'].toString(),
                  provider: ProviderType.appleMusic,
                  title: aMap['title'] as String,
                  episode: aMap['episode'] as int?,
                );
              }).toList();

      final amArtistIdsRaw = appleMusicMap?['artist_ids'] as YamlList?;
      // Apple Music IDs are quoted strings in YAML but YAML parsers may
      // return them as integers. toString() handles both cases safely.
      final amArtistIds =
          amArtistIdsRaw == null
              ? <String>[]
              : amArtistIdsRaw.map<String>((a) => a.toString()).toList();

      parsed.add(
        CatalogSeries(
          id: map['id'] as String,
          title: map['title'] as String,
          aliases: aliases,
          spotifyArtistIds: artistIds,
          appleMusicArtistIds: amArtistIds,
          coverUrl: map['cover_url'] as String?,
          contentType: ContentType.fromString(map['content_type'] as String?),
          albums: albums,
          appleMusicAlbums: amAlbums,
        ),
      );
    }

    final curated = parsed.where((s) => s.hasCuratedAlbums).length;
    final service = CatalogService._(parsed);
    Log.info(
      _tag,
      'Catalog loaded',
      data: {
        'series': '${parsed.length}',
        'curated': '$curated',
        'albums': '${service.albumCount}',
      },
    );

    return service;
  }

  /// Look up a discovered album in the catalog by its provider+id.
  ///
  /// Returns the owning series and the extracted episode number if the
  /// album_id is in our curated catalog. Returns null otherwise — we don't
  /// fall back to fuzzy keyword/artist heuristics, which historically
  /// produced false positives (a search for "blaze" being tagged as
  /// Encanto because both albums shared the phrase "Das Original-Hörspiel"
  /// in their titles). A clean contract: in the catalog → identified;
  /// not in the catalog → no badge.
  ///
  /// Coverage of new releases / under-discovered albums is intentionally
  /// left to the planned subscription/refresh feature, which can detect
  /// genuinely new albums without guessing at series membership.
  CatalogMatch? match(
    String title, {
    required String albumId,
    required ProviderType albumProvider,
  }) {
    final hit = _albumIndex['${albumProvider.value}:$albumId'];
    if (hit == null) {
      Log.debug(_tag, 'No match', data: {'title': title, 'albumId': albumId});
      return null;
    }
    Log.debug(
      _tag,
      'Matched',
      data: {
        'title': title,
        'series': hit.series.id,
        'albumId': albumId,
        'episode': '${hit.album.episode}',
      },
    );
    // The curated number, never a fresh derivation. It was produced by the
    // Python pipeline, audited and drift-checked; a regex over a mutable
    // provider title is strictly weaker (see docs/catalog-episode-numbers.md).
    return CatalogMatch(series: hit.series, episodeNumber: hit.album.episode);
  }

  /// The curated album record for a provider id, or null if the catalog
  /// does not know it.
  ///
  /// Exposed so callers can read the curated episode number without
  /// pretending to match a title, which [match] needs only for its log
  /// line.
  CatalogAlbum? curatedAlbum(
    String albumId, {
    required ProviderType provider,
  }) => _albumIndex['${provider.value}:$albumId']?.album;

  /// All series sorted alphabetically — for UI display.
  List<CatalogSeries> get all => List.unmodifiable(_series);

  /// Search series by title or alias (local, instant). Returns matches
  /// sorted by relevance: exact title prefix first, then contains-matches
  /// against title or aliases.
  List<CatalogSeries> search(String query) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    final titlePrefixMatches = <CatalogSeries>[];
    final substringMatches = <CatalogSeries>[];
    for (final s in _series) {
      if (s.title.toLowerCase().startsWith(q)) {
        titlePrefixMatches.add(s);
      } else if (s.title.toLowerCase().contains(q) ||
          s.aliases.any((a) => a.toLowerCase().contains(q))) {
        substringMatches.add(s);
      }
    }
    final results = [...titlePrefixMatches, ...substringMatches];
    Log.debug(
      _tag,
      'Search',
      data: {'query': query, 'results': '${results.length}'},
    );
    return results;
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// A curated album together with the series that owns it.
class _IndexedAlbum {
  const _IndexedAlbum(this.series, this.album);

  final CatalogSeries series;
  final CatalogAlbum album;
}

/// Loaded catalog service. Null while loading; the app can handle the
/// loading state gracefully (catalog match is optional, never blocking).
final catalogServiceProvider = FutureProvider<CatalogService>(
  (ref) => CatalogService.load(),
);
