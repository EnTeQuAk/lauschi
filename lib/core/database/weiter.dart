/// Where a kid continues inside a tile: the "Weiter" item.
///
/// The tile stores it (`Groups.weiterItemId`), so nothing here guesses
/// from heard flags or saved positions. These two functions only resolve
/// the stored id against the tile's current, ordered item list.
library;

import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart'
    show isItemUnavailable;

/// The item that follows [finishedId] in [items], skipping unavailable
/// ones and wrapping to the start of the list.
///
/// Heard state plays no part: after an episode comes the next one, also
/// when the kid hears the series a second time. Bonus items (no episode
/// number) sort last, so they follow the numbered run. Returns null when
/// nothing in the tile is playable.
TileItem? nextAfter(List<TileItem> items, String finishedId) {
  final index = items.indexWhere((item) => item.id == finishedId);
  for (var step = 1; step <= items.length; step++) {
    final candidate = items[(index + step) % items.length];
    if (!isItemUnavailable(candidate)) return candidate;
  }
  return null;
}

/// The Weiter item of a tile with the given [items] (in list order).
///
/// The stored [weiterItemId] wins. When that item is unavailable, the
/// badge moves on to the next playable one, and when there is no stored
/// id (a tile nobody listened to yet) or the item has left the tile, the
/// kid starts at the first playable item.
TileItem? weiterFor(List<TileItem> items, String? weiterItemId) {
  final stored = items.where((item) => item.id == weiterItemId).firstOrNull;
  if (stored == null) {
    return items.where((item) => !isItemUnavailable(item)).firstOrNull;
  }
  if (!isItemUnavailable(stored)) return stored;
  return nextAfter(items, stored.id);
}
