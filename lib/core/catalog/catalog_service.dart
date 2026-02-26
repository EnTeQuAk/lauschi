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
          episodePattern: _parseEpisodePattern(map['episode_pattern']),
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

  // German letters for whole-word boundary checks. Lowercase only since
  // titles are lowered before matching.
  static final _germanLetter = RegExp('[a-zäöüß]');

  /// Whether [keyword] matches in [titleLower] respecting word boundaries.
  ///
  /// Multi-word keywords (containing spaces) use substring matching since
  /// spaces provide natural word boundaries. Single-word keywords require
  /// whole-word boundaries: the characters immediately before and after the
  /// match must not be German letters. This prevents German compound word
  /// false positives like "Drachen" matching "Drachenbabys" or "Bär"
  /// matching "Bären".
  ///
  /// Checks ALL occurrences, not just the first. "Die Tigerbären und der
  /// kleine Tiger" must find the second standalone "Tiger".
  bool _keywordMatches(String titleLower, String keyword) {
    // Multi-word keywords have natural boundaries from spaces.
    if (keyword.contains(' ')) return titleLower.contains(keyword);

    // Single-word: find any occurrence with whole-word boundaries.
    var start = 0;
    while (true) {
      final index = titleLower.indexOf(keyword, start);
      if (index == -1) return false;

      final beforeOk =
          index == 0 || !_germanLetter.hasMatch(titleLower[index - 1]);
      final afterIndex = index + keyword.length;
      final afterOk =
          afterIndex >= titleLower.length ||
          !_germanLetter.hasMatch(titleLower[afterIndex]);

      if (beforeOk && afterOk) return true;
      start = index + 1;
    }
  }

  /// Match [title] against all known series using a two-phase strategy.
  ///
  /// **Phase 1 — keyword match** with whole-word boundaries for single-word
  ///   keywords. Prevents German compound false positives ("Drachenbabys"
  ///   won't match "Drachen"). When multiple series match, the artist ID
  ///   is used as tiebreaker; otherwise the most specific keyword wins
  ///   (series are pre-sorted by keyword length descending).
  ///
  /// **Phase 2 — artist ID match** (fallback for structurally-missing names):
  ///   Used when no keyword fires. Catches albums whose titles contain no
  ///   series name (e.g. TKKG "140/Draculas Erben", compound-word titles
  ///   like "Drachenreiter" where the standalone keyword check rejects the
  ///   compound but the artist ID correctly identifies the series).
  ///
  /// Pass [albumArtistIds] (from `SpotifyAlbum.artistIds`) for best results.
  /// Returns null if no series is recognized by either strategy.
  CatalogMatch? match(String title, {List<String> albumArtistIds = const []}) {
    final titleLower = title.toLowerCase();

    // Phase 1: collect keyword matches using whole-word boundaries.
    final keywordMatches = <CatalogSeries>[];
    for (final series in _series) {
      if (series.keywords.any((k) => _keywordMatches(titleLower, k))) {
        keywordMatches.add(series);
      }
    }

    // Phase 2: find first artist ID match.
    CatalogSeries? artistMatch;
    if (albumArtistIds.isNotEmpty) {
      final artistIdSet = albumArtistIds.toSet();
      for (final series in _series) {
        if (series.spotifyArtistIds.any(artistIdSet.contains)) {
          artistMatch = series;
          break;
        }
      }
    }

    // Resolve: keyword matches take priority, artist ID is tiebreaker/fallback.
    if (keywordMatches.isNotEmpty) {
      // If artist confirms one of the keyword candidates, it wins.
      final winner =
          (artistMatch != null &&
                  keywordMatches.any((s) => s.id == artistMatch!.id))
              ? artistMatch
              : keywordMatches
                  .first; // Most specific (longest keyword, pre-sorted)

      return CatalogMatch(
        series: winner,
        // Keyword found it, even if artist confirmed it.
        source: CatalogMatchSource.keyword,
        episodeNumber: _extractEpisode(title, winner.episodePattern),
      );
    }

    // No keyword matches — fall back to artist ID alone.
    if (artistMatch != null) {
      return CatalogMatch(
        series: artistMatch,
        source: CatalogMatchSource.artistId,
        episodeNumber: _extractEpisode(title, artistMatch.episodePattern),
      );
    }

    return null;
  }

  /// All series sorted alphabetically — for UI display.
  List<CatalogSeries> get all => List.unmodifiable(_series);

  /// Search series by title/keyword (local, instant). Returns matches sorted
  /// by relevance: exact title prefix first, then keyword matches.
  List<CatalogSeries> search(String query) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase();
    final titlePrefixMatches = <CatalogSeries>[];
    final keywordMatches = <CatalogSeries>[];
    for (final s in _series) {
      if (s.title.toLowerCase().startsWith(q)) {
        titlePrefixMatches.add(s);
      } else if (s.title.toLowerCase().contains(q) ||
          s.aliases.any((a) => a.toLowerCase().contains(q)) ||
          s.keywords.any((k) => k.toLowerCase().contains(q))) {
        keywordMatches.add(s);
      }
    }
    return [...titlePrefixMatches, ...keywordMatches];
  }

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

/// Parse episode_pattern from YAML: accepts a single string or a list of
/// strings (joined with `|` into one alternation regex).
String? _parseEpisodePattern(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  if (raw is List) return raw.cast<String>().map((p) => '(?:$p)').join('|');
  return raw.toString();
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Loaded catalog service. Null while loading; the app can handle the
/// loading state gracefully (catalog match is optional, never blocking).
final catalogServiceProvider = FutureProvider<CatalogService>(
  (ref) => CatalogService.load(),
);
