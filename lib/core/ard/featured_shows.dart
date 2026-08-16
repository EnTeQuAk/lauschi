import 'package:flutter/foundation.dart' show visibleForTesting;
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
  const FeaturedShowEntry({required this.id});

  final String id;
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
            return FeaturedShowEntry(id: '${map['id']}');
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
    required this.showTitle,
    required this.showId,
  });

  /// Display title (without part suffix).
  final String title;

  /// Individual episode parts, sorted by part number.
  final List<ArdItem> parts;

  /// The show (programSet) this item belongs to, e.g. "Die Maus". Shown
  /// as the card subtitle so a parent sees which show it came from.
  final String? showTitle;

  /// ARD show ID this item was fetched from.
  final String showId;

  /// The primary (first) part — used for display metadata like the cover.
  ArdItem get primary => parts.first;
  String? get imageUrl => primary.imageUrl;

  /// The newest part's publish date: when the story last had activity.
  /// Sorting and the "Neu" badge use this so a story that just finished a
  /// new part ranks as fresh, not by its oldest part.
  DateTime get publishDate =>
      parts.map((p) => p.publishDate).reduce((a, b) => a.isAfter(b) ? a : b);

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

/// Group a show's items into featured items, merging explicit multi-part
/// stories and leaving standalone episodes separate.
///
/// Only episodes carrying an explicit "(N/M)" suffix that share a base
/// title are merged into one multi-part item. Episodes without a suffix
/// each stay standalone (keyed by id), so distinct episodes that happen to
/// share a title (a daily "Gute-Nacht-Geschichte") don't collapse into one
/// fake multi-part card.
@visibleForTesting
List<FeaturedItem> groupFeaturedItems(List<ArdItem> items, String showId) {
  final groups =
      <String, ({List<ArdItem> parts, String title, String? show})>{};

  for (final item in items) {
    final match = _multiPartRegex.firstMatch(item.title);
    final baseTitle = match != null ? match.group(1)!.trim() : item.title;
    final key = match != null ? baseTitle : item.id;

    groups
        .putIfAbsent(
          key,
          () => (parts: [], title: baseTitle, show: item.programSetTitle),
        )
        .parts
        .add(item);
  }

  return groups.values.map((group) {
      // Sort parts by part number if multi-part, else by publish date.
      final parts =
          group.parts..sort((a, b) {
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
        title: group.title,
        parts: parts,
        showTitle: group.show,
        showId: showId,
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
  final cutoff = DateTime.now().subtract(_maxAge);

  // Fetch all shows in parallel — they're independent.
  // Returns (showId, items) pairs so we can group per-show.
  final results = await Future.wait(
    config.shows.map((show) async {
      try {
        final page = await api.getItems(
          programSetId: show.id,
          first: _itemsPerShow,
        );

        // Drop only unplayable parts here. Recency is decided per story
        // below (on its newest part), not per part, so a recently finished
        // multi-part story isn't gapped by an old early part.
        //
        // endDate is the editorial broadcast window, NOT content removal.
        // Audio URLs remain accessible on CDN after endDate passes.
        // Verified: WDR shows have 1-day windows but CDN serves for weeks.
        final playable =
            page.items.where((item) => item.bestAudioUrl != null).toList();
        return (showId: show.id, items: playable);
      } on Exception catch (e) {
        // Skip shows that fail — don't let one bad show break all.
        Log.error(_tag, 'Failed to fetch show ${show.id}', exception: e);
        return (showId: show.id, items: <ArdItem>[]);
      }
    }),
  );

  // Group per-show (each FeaturedItem carries its source show ID), then
  // keep stories whose newest part is recent enough, newest first.
  final allItems =
      results
          .expand((r) => groupFeaturedItems(r.items, r.showId))
          .where((item) => item.publishDate.isAfter(cutoff))
          .toList()
        ..sort((a, b) => b.publishDate.compareTo(a.publishDate));

  Log.info(
    _tag,
    'Fetched featured items',
    data: {'total': '${allItems.length}'},
  );

  return allItems;
}

// ── Provider ────────────────────────────────────────────────────────────────

@riverpod
Future<List<FeaturedItem>> featuredItems(Ref ref) {
  final api = ref.watch(ardApiProvider);
  return _fetchFeaturedItems(api);
}
