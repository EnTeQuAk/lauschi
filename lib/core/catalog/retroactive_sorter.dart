import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';

const _tag = 'RetroactiveSorter';

/// Result of matching ungrouped cards to catalog series.
class SortResult {
  const SortResult({
    required this.totalUngrouped,
    required this.totalMatched,
    required this.seriesMatches,
    required this.seriesGroupIds,
  });

  /// How many ungrouped cards were examined.
  final int totalUngrouped;

  /// How many were successfully matched and assigned.
  final int totalMatched;

  /// Series title → number of cards assigned.
  final Map<String, int> seriesMatches;

  /// Series title → group ID (for navigation after sort).
  final Map<String, String> seriesGroupIds;

  bool get hasMatches => totalMatched > 0;
}

/// Match ungrouped cards against the catalog and assign them to groups.
///
/// Pure business logic — no UI, no dialogs. Returns a [SortResult]
/// describing what was matched.
Future<SortResult> runRetroactiveSort({
  required CatalogService catalog,
  required CardRepository cardRepo,
  required GroupRepository groupRepo,
}) async {
  final ungrouped = await cardRepo.getUngrouped();
  final grouped = <String, String>{}; // seriesTitle → groupId
  final groupedCounts = <String, int>{}; // seriesTitle → card count
  var matchCount = 0;

  for (final card in ungrouped) {
    final artistIds =
        card.spotifyArtistIds
            ?.split(',')
            .where((s) => s.isNotEmpty)
            .toList() ??
        const [];
    final match = catalog.match(card.title, albumArtistIds: artistIds);
    if (match == null) continue;

    final title = match.series.title;
    if (!grouped.containsKey(title)) {
      final existing = await groupRepo.findByTitle(title);
      grouped[title] = existing?.id ?? await groupRepo.insert(title: title);
    }

    await cardRepo.assignToGroup(
      cardId: card.id,
      groupId: grouped[title]!,
      episodeNumber: match.episodeNumber,
    );
    groupedCounts[title] = (groupedCounts[title] ?? 0) + 1;
    matchCount++;
  }

  Log.info(
    _tag,
    'Retroactive sort complete',
    data: {
      'ungrouped': '${ungrouped.length}',
      'matched': '$matchCount',
      'series': '${grouped.length}',
    },
  );

  return SortResult(
    totalUngrouped: ungrouped.length,
    totalMatched: matchCount,
    seriesMatches: groupedCounts,
    seriesGroupIds: grouped,
  );
}
