import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';

const _tag = 'ArdAvailabilityRecheck';

/// Minimum time between rechecks for the same item.
const _recheckInterval = Duration(days: 7);

/// Re-checks ARD items marked unavailable to see if content returned.
///
/// Runs on app launch. Only rechecks items that were marked unavailable
/// more than 7 days ago to avoid hammering the API. If the item has
/// audio again, clears the flag so kids can play it.
///
/// Skips on any API error (network, timeout) to avoid false positives.
Future<void> recheckArdAvailability({
  required ArdApi api,
  required TileItemRepository items,
}) async {
  final unavailable = await items.getUnavailable(olderThan: _recheckInterval);

  // Only recheck ARD items. Spotify/Apple Music availability is checked
  // during playback, not via batch recheck.
  final ardItems =
      unavailable
          .where((i) => i.provider == ProviderType.ardAudiothek.value)
          .toList();

  if (ardItems.isEmpty) return;

  Log.info(
    _tag,
    'Rechecking availability',
    data: {'count': '${ardItems.length}'},
  );

  var restored = 0;
  for (final item in ardItems) {
    final ardId = ProviderType.extractId(item.providerUri);
    if (ardId == null) continue;

    try {
      final episode = await api.getItem(ardId);
      if (episode != null && episode.bestAudioUrl != null) {
        await items.clearUnavailable(item.id);
        restored++;
        Log.info(
          _tag,
          'Content restored',
          data: {'id': item.id, 'title': item.title},
        );
      }
    } on Exception {
      // Network error or API issue: skip this item, don't change state.
      // Will retry on next launch after the recheck interval.
    }
  }

  if (restored > 0) {
    Log.info(
      _tag,
      'Recheck complete',
      data: {'checked': '${ardItems.length}', 'restored': '$restored'},
    );
  }
}
