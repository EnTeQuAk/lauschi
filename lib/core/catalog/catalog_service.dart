import 'dart:isolate';

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
    this.releaseDate,
  });

  /// Provider-specific album ID.
  final String id;

  /// Which provider this album belongs to.
  final ProviderType provider;

  final String title;
  final int? episode;

  /// Release date as shipped by the pipeline (ISO `YYYY-MM-DD`). Null for
  /// entries curated before the field existed.
  final String? releaseDate;

  /// Whether the album is out on [now]. A pre-release is curated and
  /// indexed like any other album but hidden from listings until its
  /// date, so it appears on its own without a catalog update. A missing
  /// or unparseable date (Apple Music sometimes ships a bare year) is
  /// ambiguous and never hides an album.
  bool isAvailableOn(DateTime now) {
    final date = releaseDate;
    if (date == null) return true;
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return true;
    final today = DateTime(now.year, now.month, now.day);
    return !parsed.isAfter(today);
  }

  /// Full provider URI for DB storage (e.g. 'spotify:album:abc123').
  String get uri => provider.albumUri(id);
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
  /// Parsed from the catalog but not yet consumed by the app: the
  /// cover picker's artist-portrait rail is Spotify-only because
  /// Apple Music search results carry no artist ids to store.
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

  /// Curated albums for a provider that are out on [now] (defaults to
  /// today). Pre-releases stay in [albums] for the id index but are not
  /// listed until their release date.
  List<CatalogAlbum> albumsForProvider(ProviderType provider, {DateTime? now}) {
    final all = switch (provider) {
      ProviderType.spotify => albums,
      ProviderType.appleMusic => appleMusicAlbums,
      _ => const <CatalogAlbum>[],
    };
    final at = now ?? DateTime.now();
    return all.where((a) => a.isAvailableOn(at)).toList();
  }

  /// Whether this series has curated albums for a specific provider.
  bool hasCuratedAlbumsFor(ProviderType provider) =>
      albumsForProvider(provider).isNotEmpty;
}

/// Result when a catalog match is found.
class CatalogMatch {
  const CatalogMatch({required this.series, this.episodeNumber});

  final CatalogSeries series;

  /// The curated episode number from series.yaml, or null when the
  /// curated album carries none (music, films, specials).
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
  /// When a discovered album's id is in the catalog, the lookup is O(1).
  /// Carrying the album (not just the series) is what lets [match] return
  /// the curated episode number instead of re-deriving one.
  ///
  /// An id curated under multiple series resolves to whichever series
  /// parses last. [findSharedAlbumIds] detects those; [load] logs them
  /// so curation bleed is visible instead of silently mis-attributing.
  final Map<String, _IndexedAlbum> _albumIndex;

  /// The [_albumIndex] key for a provider+album id pair.
  static String _albumKey(ProviderType provider, String id) =>
      '${provider.value}:$id';

  static Map<String, _IndexedAlbum> _buildAlbumIndex(
    List<CatalogSeries> series,
  ) {
    final out = <String, _IndexedAlbum>{};
    for (final s in series) {
      for (final a in s.albums) {
        out[_albumKey(a.provider, a.id)] = _IndexedAlbum(s, a);
      }
      for (final a in s.appleMusicAlbums) {
        out[_albumKey(a.provider, a.id)] = _IndexedAlbum(s, a);
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
    // The 1.6 MB YAML document takes hundreds of milliseconds of pure
    // Dart parsing. On the UI isolate that would jank the first frames
    // of the kid home screen on every cold start, because the startup
    // episode reconcile forces this load during launch.
    final result = await Isolate.run(() => parseSeriesYaml(raw));

    for (final error in result.errors) {
      Log.error(_tag, 'Skipped malformed series entry', data: {'entry': error});
    }

    final parsed = result.series;
    final shared = result.sharedAlbumIds;
    if (shared.isNotEmpty) {
      Log.warn(
        _tag,
        'Album ids curated under multiple series',
        data: {
          'count': '${shared.length}',
          'sample': shared.entries
              .take(3)
              .map((e) => '${e.key}=${e.value.join('/')}')
              .join(', '),
        },
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

  /// Parse the series.yaml document. Pure computation: no I/O and no
  /// logging, so it can run on a background isolate. Also computes the
  /// cross-series shared album ids there, so [load] only logs them.
  ///
  /// A malformed series entry is skipped and reported in `errors`
  /// instead of failing the parse: one bad row must not take down
  /// badges, browse, and reconcile for the other ~270 series. A
  /// document that is not valid YAML at all still throws.
  static ({
    List<CatalogSeries> series,
    List<String> errors,
    Map<String, List<String>> sharedAlbumIds,
  })
  parseSeriesYaml(String raw) {
    final doc = loadYaml(raw) as YamlMap;
    final seriesList = doc['series'] as YamlList;

    final parsed = <CatalogSeries>[];
    final errors = <String>[];
    for (final (index, entry) in seriesList.indexed) {
      try {
        parsed.add(_parseSeries(entry as YamlMap));
        // Cast failures throw TypeError — an Error, not an Exception —
        // and a bad entry of any shape must be skipped, not crash the
        // parse of every other series.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        final id = entry is YamlMap ? entry['id'] : null;
        errors.add('series[$index] (id: ${id ?? 'unknown'}): $e');
      }
    }
    return (
      series: parsed,
      errors: errors,
      sharedAlbumIds: findSharedAlbumIds(parsed),
    );
  }

  /// Album ids curated under more than one series, keyed by
  /// ``'<provider>:<album_id>'`` with the owning series ids as value.
  ///
  /// Shared ids are mostly collaboration music albums. [match] resolves
  /// them to a single arbitrary owner, so a Hörspiel entry here is a
  /// curation bug: the kid's episode lands in the wrong tile.
  static Map<String, List<String>> findSharedAlbumIds(
    List<CatalogSeries> series,
  ) {
    final owners = <String, List<String>>{};
    for (final s in series) {
      for (final a in s.albums) {
        (owners[_albumKey(a.provider, a.id)] ??= []).add(s.id);
      }
      for (final a in s.appleMusicAlbums) {
        (owners[_albumKey(a.provider, a.id)] ??= []).add(s.id);
      }
    }
    return {
      for (final e in owners.entries)
        if (e.value.length > 1) e.key: e.value,
    };
  }

  /// Items of [list] as strings via toString(): ids may be quoted
  /// strings in YAML but parse as integers.
  static List<String> _stringList(YamlList? list) =>
      list == null ? const [] : list.map((e) => e.toString()).toList();

  static List<CatalogAlbum> _albumList(YamlList? list, ProviderType provider) =>
      list == null
          ? const []
          : list.map<CatalogAlbum>((a) {
            final aMap = a as YamlMap;
            return CatalogAlbum(
              id: aMap['id'].toString(),
              provider: provider,
              title: aMap['title'] as String,
              episode: aMap['episode'] as int?,
              releaseDate: aMap['release_date']?.toString(),
            );
          }).toList();

  static CatalogSeries _parseSeries(YamlMap map) {
    // Per-provider identifiers come from the `providers:` map.
    final providersMap = map['providers'] as YamlMap?;
    final spotifyMap = providersMap?['spotify'] as YamlMap?;
    final appleMusicMap = providersMap?['apple_music'] as YamlMap?;

    return CatalogSeries(
      id: map['id'] as String,
      title: map['title'] as String,
      aliases: _stringList(map['aliases'] as YamlList?),
      spotifyArtistIds: _stringList(spotifyMap?['artist_ids'] as YamlList?),
      appleMusicArtistIds: _stringList(
        appleMusicMap?['artist_ids'] as YamlList?,
      ),
      coverUrl: map['cover_url'] as String?,
      contentType: ContentType.fromString(map['content_type'] as String?),
      albums: _albumList(
        spotifyMap?['albums'] as YamlList?,
        ProviderType.spotify,
      ),
      appleMusicAlbums: _albumList(
        appleMusicMap?['albums'] as YamlList?,
        ProviderType.appleMusic,
      ),
    );
  }

  /// Look up a discovered album in the catalog by its provider+id.
  ///
  /// Returns the owning series and the curated episode number if the
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
    final hit = _albumIndex[_albumKey(albumProvider, albumId)];
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
  }) => _albumIndex[_albumKey(provider, albumId)]?.album;

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
