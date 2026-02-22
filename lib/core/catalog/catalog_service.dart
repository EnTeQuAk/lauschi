import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

/// A pre-validated album entry in the catalog.
class CatalogAlbum {
  const CatalogAlbum({
    required this.spotifyId,
    required this.title,
    this.episode,
  });

  /// Spotify album ID (the part after `spotify:album:`).
  final String spotifyId;
  final String title;
  final int? episode;

  /// Full Spotify URI.
  String get uri => 'spotify:album:$spotifyId';
}

/// A single known Hörspiel series from the bundled catalog.
class CatalogSeries {
  const CatalogSeries({
    required this.id,
    required this.title,
    required this.aliases,
    required this.keywords,
    required this.spotifyArtistIds,
    this.coverUrl,
    this.episodePattern,
    this.albums = const [],
  });

  final String id;
  final String title;
  final List<String> aliases;

  /// Single-word or phrase tokens to detect this series in search results.
  /// Matched case-insensitively. Longer keywords are checked first to
  /// avoid matching a broad series before a more specific one (e.g.,
  /// "drei ??? kids" before "drei ???").
  final List<String> keywords;

  /// Spotify artist IDs whose albums belong to this series.
  ///
  /// Used as a secondary (phase-2) match when the album title contains no
  /// series name (e.g. TKKG "140/Draculas Erben", Die drei ??? "116/Cobra").
  /// Pass them to `CatalogService.match()` via the `albumArtistIds` parameter
  /// so phase-2 matching can fire for albums with no series name in their title.
  final List<String> spotifyArtistIds;

  /// Curated cover image URL for this series.
  /// Typically the Spotify artist image or a hand-picked cover.
  final String? coverUrl;

  /// Regex with one capture group for the episode number.
  final String? episodePattern;

  /// Pre-validated album list with Spotify IDs and episode numbers.
  /// Empty for series that haven't been fully curated yet.
  final List<CatalogAlbum> albums;

  /// Whether this series has a curated album list.
  bool get hasCuratedAlbums => albums.isNotEmpty;
}

/// How a catalog match was found — useful for display/confidence decisions.
enum CatalogMatchSource {
  /// Album title contained a series keyword.
  keyword,

  /// Album had a Spotify artist ID matching a known series.
  /// (Series name not necessarily in the album title.)
  artistId,
}

/// Result when a catalog match is found.
class CatalogMatch {
  const CatalogMatch({
    required this.series,
    required this.source,
    this.episodeNumber,
  });

  final CatalogSeries series;
  final CatalogMatchSource source;

  /// Extracted episode number, or null if title format didn't match.
  final int? episodeNumber;
}

/// Loads and provides the DACH Hörspiel series catalog from bundled assets.
///
/// The catalog is heuristic — used to suggest group assignments when adding
/// cards. It is not a sync mechanism; episode lists may be incomplete.
class CatalogService {
  CatalogService._(this._series);

  final List<CatalogSeries> _series;

  /// Number of known series.
  int get seriesCount => _series.length;

  /// Load the catalog from bundled YAML asset.
  static Future<CatalogService> load() async {
    final raw = await rootBundle.loadString('assets/catalog/series.yaml');
    final doc = loadYaml(raw) as YamlMap;
    final seriesList = doc['series'] as YamlList;

    final parsed = <CatalogSeries>[];
    for (final entry in seriesList) {
      final map = entry as YamlMap;

      // Sort keywords by length descending — more specific first
      final keywordsRaw = map['keywords'] as YamlList?;
      final keywords =
          keywordsRaw == null
              ? <String>[]
              : (keywordsRaw
                  .map<String>((k) => (k as String).toLowerCase())
                  .toList()
                ..sort((a, b) => b.length.compareTo(a.length)));

      final artistIdsRaw = map['spotify_artist_ids'] as YamlList?;
      final artistIds =
          artistIdsRaw == null
              ? <String>[]
              : artistIdsRaw.map<String>((a) => a as String).toList();

      final aliasesRaw = map['aliases'] as YamlList?;
      final aliases =
          aliasesRaw == null
              ? <String>[]
              : aliasesRaw.map<String>((a) => a as String).toList();

      final albumsRaw = map['albums'] as YamlList?;
      final albums =
          albumsRaw == null
              ? <CatalogAlbum>[]
              : albumsRaw.map<CatalogAlbum>((a) {
                final aMap = a as YamlMap;
                return CatalogAlbum(
                  spotifyId: aMap['id'] as String,
                  title: aMap['title'] as String,
                  episode: aMap['episode'] as int?,
                );
              }).toList();

      parsed.add(
        CatalogSeries(
          id: map['id'] as String,
          title: map['title'] as String,
          aliases: aliases,
          keywords: keywords,
          spotifyArtistIds: artistIds,
          coverUrl: map['cover_url'] as String?,
          episodePattern: map['episode_pattern'] as String?,
          albums: albums,
        ),
      );
    }

    // Sort series so more specific ones (longer primary keyword) come first.
    // This prevents "Die drei ???" from stealing "Die drei ??? Kids" matches.
    parsed.sort(
      (a, b) => (b.keywords.firstOrNull?.length ?? 0).compareTo(
        a.keywords.firstOrNull?.length ?? 0,
      ),
    );

    return CatalogService._(parsed);
  }

  /// Match [title] against all known series using a two-phase strategy.
  ///
  /// **Phase 1 — keyword match** (most specific):
  ///   If [albumArtistIds] is provided AND matches a series that also has a
  ///   keyword hit, this is returned first. Otherwise the first series whose
  ///   keyword appears in [title] is returned.
  ///
  /// **Phase 2 — artist ID match** (fallback for structurally-missing names):
  ///   Used when no keyword fires. Catches albums whose titles contain no series
  ///   name (e.g. TKKG, Die drei ???, Die Fuchsbande, Fünf Freunde).
  ///
  /// Pass [albumArtistIds] (from `SpotifyAlbum.artistIds`) for best results.
  /// Returns null if no series is recognized by either strategy.
  CatalogMatch? match(String title, {List<String> albumArtistIds = const []}) {
    final lower = title.toLowerCase();

    // Phase 1: keyword match
    for (final series in _series) {
      for (final keyword in series.keywords) {
        if (lower.contains(keyword)) {
          final episode = _extractEpisode(title, series.episodePattern);
          return CatalogMatch(
            series: series,
            source: CatalogMatchSource.keyword,
            episodeNumber: episode,
          );
        }
      }
    }

    // Phase 2: artist ID match (only when albumArtistIds provided)
    if (albumArtistIds.isNotEmpty) {
      for (final series in _series) {
        for (final artistId in series.spotifyArtistIds) {
          if (albumArtistIds.contains(artistId)) {
            final episode = _extractEpisode(title, series.episodePattern);
            return CatalogMatch(
              series: series,
              source: CatalogMatchSource.artistId,
              episodeNumber: episode,
            );
          }
        }
      }
    }

    return null;
  }

  /// All series sorted alphabetically — for UI display.
  List<CatalogSeries> get all => List.unmodifiable(_series);

  int? _extractEpisode(String title, String? pattern) {
    if (pattern == null) return null;
    final regex = RegExp(pattern, caseSensitive: false);
    final m = regex.firstMatch(title);
    if (m == null) return null;

    // Walk groups left-to-right: the first non-null capture group wins.
    // This gives preference to the leftmost (most specific) alternative in
    // alternation patterns like (?:^(\d{1,3})/|[Ff]olge\s+(\d+)).
    for (var i = 1; i <= m.groupCount; i++) {
      final group = m.group(i);
      if (group != null) {
        final digits = group.replaceAll(RegExp(r'\D'), '');
        if (digits.isNotEmpty) {
          final n = int.tryParse(digits);
          if (n != null && n > 0) return n;
        }
      }
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Loaded catalog service. Null while loading; the app can handle the
/// loading state gracefully (catalog match is optional, never blocking).
final catalogServiceProvider = FutureProvider<CatalogService>(
  (ref) => CatalogService.load(),
);
