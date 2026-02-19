import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

/// A single known Hörspiel series from the bundled catalog.
class CatalogSeries {
  const CatalogSeries({
    required this.id,
    required this.title,
    required this.aliases,
    required this.keywords,
    this.episodePattern,
  });

  final String id;
  final String title;
  final List<String> aliases;

  /// Single-word or phrase tokens to detect this series in search results.
  /// Matched case-insensitively. Longer keywords are checked first to
  /// avoid matching a broad series before a more specific one (e.g.,
  /// "drei ??? kids" before "drei ???").
  final List<String> keywords;

  /// Regex with one capture group for the episode number.
  final String? episodePattern;
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
      final keywords = (map['keywords'] as YamlList)
          .map<String>((k) => (k as String).toLowerCase())
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));

      parsed.add(CatalogSeries(
        id: map['id'] as String,
        title: map['title'] as String,
        aliases: (map['aliases'] as YamlList)
            .map<String>((a) => a as String)
            .toList(),
        keywords: keywords,
        episodePattern: map['episode_pattern'] as String?,
      ));
    }

    // Sort series so more specific ones (longer primary keyword) come first.
    // This prevents "Die drei ???" from stealing "Die drei ??? Kids" matches.
    parsed.sort(
      (a, b) => (b.keywords.firstOrNull?.length ?? 0)
          .compareTo(a.keywords.firstOrNull?.length ?? 0),
    );

    return CatalogService._(parsed);
  }

  /// Match [title] against all known series.
  ///
  /// Returns the first match found, or null if no series is recognized.
  /// Matching checks each series' keywords in specificity order (longest
  /// keyword first within each series).
  CatalogMatch? match(String title) {
    final lower = title.toLowerCase();
    for (final series in _series) {
      for (final keyword in series.keywords) {
        if (lower.contains(keyword)) {
          final episode = _extractEpisode(title, series.episodePattern);
          return CatalogMatch(series: series, episodeNumber: episode);
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
    final match = regex.firstMatch(title);
    if (match == null) return null;

    // Find the last group with digits
    for (var i = match.groupCount; i >= 1; i--) {
      final group = match.group(i);
      if (group != null) {
        final n = int.tryParse(group.replaceAll(RegExp(r'\D'), ''));
        if (n != null) return n;
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
final catalogServiceProvider =
    FutureProvider<CatalogService>((ref) => CatalogService.load());
