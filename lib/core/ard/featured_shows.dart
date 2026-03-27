import 'package:flutter/services.dart' show rootBundle;
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:yaml/yaml.dart';

part 'featured_shows.g.dart';

const _tag = 'FeaturedShows';
const _configPath = 'assets/catalog/ard_featured_shows.yaml';

/// Max age of featured items to display.
const _maxAge = Duration(days: 365);

/// Max items to fetch per show.
const _itemsPerShow = 10;

// ── Config model ────────────────────────────────────────────────────────────

class FeaturedShowEntry {
  const FeaturedShowEntry({required this.id, this.minDurationSeconds = 1200});

  final String id;
  final int minDurationSeconds;
}

class FeaturedShowsConfig {
  const FeaturedShowsConfig({required this.shows});

  factory FeaturedShowsConfig.fromYaml(String yaml) {
    final doc = loadYaml(yaml) as YamlMap;
    final list = doc['featured_shows'] as YamlList;

    return FeaturedShowsConfig(
      shows:
          list.map((entry) {
            final map = entry as YamlMap;
            return FeaturedShowEntry(
              id: '${map['id']}',
              minDurationSeconds: map['min_duration_seconds'] as int? ?? 1200,
            );
          }).toList(),
    );
  }

  final List<FeaturedShowEntry> shows;
}

// ── Multi-part grouping ─────────────────────────────────────────────────────

/// A featured item, potentially aggregating multi-part episodes.
class FeaturedItem {
  FeaturedItem({
    required this.title,
    required this.parts,
    required this.publisher,
  });

  /// Display title (without part suffix).
  final String title;

  /// Individual episode parts, sorted by part number.
  final List<ArdItem> parts;

  /// Publisher name (e.g., "SWR Kultur").
  final String? publisher;

  /// The primary (first) part — used for display metadata.
  ArdItem get primary => parts.first;
  String? get imageUrl => primary.imageUrl;
  DateTime get publishDate => primary.publishDate;

  /// Earliest endDate across all parts, or null.
  DateTime? get endDate {
    final dates = parts.map((p) => p.endDate).whereType<DateTime>();
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Total duration across all parts.
  int get totalDurationSeconds => parts.fold(0, (sum, p) => sum + p.duration);

  bool get isMultiPart => parts.length > 1;
}

/// Regex for multi-part titles: "Title (1/2)" → (title, part, total).
final _multiPartRegex = RegExp(r'^(.+?)\s*\((\d+)/(\d+)\)\s*$');

/// Group items by base title, merging multi-part episodes.
List<FeaturedItem> _groupMultiPart(List<ArdItem> items) {
  final groups = <String, List<ArdItem>>{};
  final publisherMap = <String, String?>{};

  for (final item in items) {
    final match = _multiPartRegex.firstMatch(item.title);
    final baseTitle = match != null ? match.group(1)!.trim() : item.title;

    groups.putIfAbsent(baseTitle, () => []).add(item);
    publisherMap.putIfAbsent(baseTitle, () => item.programSetTitle);
  }

  return groups.entries.map((entry) {
      // Sort parts by part number if multi-part, else by publish date.
      final parts =
          entry.value..sort((a, b) {
            final matchA = _multiPartRegex.firstMatch(a.title);
            final matchB = _multiPartRegex.firstMatch(b.title);
            if (matchA != null && matchB != null) {
              return int.parse(
                matchA.group(2)!,
              ).compareTo(int.parse(matchB.group(2)!));
            }
            return b.publishDate.compareTo(a.publishDate);
          });

      return FeaturedItem(
        title: entry.key,
        parts: parts,
        publisher: publisherMap[entry.key],
      );
    }).toList()
    ..sort((a, b) => b.publishDate.compareTo(a.publishDate));
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Load featured items from configured ARD shows.
///
/// Fetches recent episodes from each featured show, filters by minimum
/// duration (to skip trailers), groups multi-part episodes, and sorts
/// by publish date.
Future<List<FeaturedItem>> _fetchFeaturedItems(ArdApi api) async {
  final configYaml = await rootBundle.loadString(_configPath);
  final config = FeaturedShowsConfig.fromYaml(configYaml);
  final now = DateTime.now();
  final cutoff = now.subtract(_maxAge);

  // Fetch all shows in parallel — they're independent.
  final results = await Future.wait(
    config.shows.map((show) async {
      try {
        final page = await api.getItems(
          programSetId: show.id,
          first: _itemsPerShow,
        );

        // endDate is the editorial broadcast window, NOT content removal.
        // Audio URLs remain accessible on CDN after endDate passes.
        // Verified: WDR shows have 1-day windows but CDN serves for weeks.
        return page.items
            .where(
              (item) =>
                  item.duration >= show.minDurationSeconds &&
                  item.publishDate.isAfter(cutoff) &&
                  item.bestAudioUrl != null,
            )
            .toList();
      } on Exception catch (e) {
        // Skip shows that fail — don't let one bad show break all.
        Log.error(_tag, 'Failed to fetch show ${show.id}', exception: e);
        return <ArdItem>[];
      }
    }),
  );

  final allItems = results.expand((items) => items).toList();

  Log.info(
    _tag,
    'Fetched featured items',
    data: {'total': '${allItems.length}'},
  );

  return _groupMultiPart(allItems);
}

// ── Provider ────────────────────────────────────────────────────────────────

@riverpod
Future<List<FeaturedItem>> featuredItems(Ref ref) {
  final api = ref.watch(ardApiProvider);
  return _fetchFeaturedItems(api);
}
