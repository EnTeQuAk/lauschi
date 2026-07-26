/// "Weiter" target selection, shared by the tile detail badge and the NFC
/// listener so a tag and the badge can never disagree.
///
/// Pure logic over already-sorted [TileItem]s (see `cardOrder`), no DB or
/// Flutter dependencies.
library;

import 'package:lauschi/core/database/app_database.dart';

/// How long a saved position keeps its "resume me first" privilege.
///
/// A kid who pokes at an episode for two minutes and wanders off should not
/// have the badge pinned to it days later; after this window the badge goes
/// back to following the series.
const nextUnheardStaleAfter = Duration(hours: 24);

/// Bonus content: no episode number and no manual position, so `cardOrder`
/// parks it behind everything else via the `sortLast` sentinel.
///
/// An item the parent dragged into place (sortOrder set) is part of the main
/// run even without an episode number — the manual order is the intent.
bool isBonusItem(TileItem ep) =>
    ep.sortOrder == null && ep.episodeNumber == null;

/// Pick the next episode to play from an ordered [episodes] list.
///
/// The numbered run is resolved first and bonus content only comes up once
/// the run is exhausted. Otherwise an abandoned bonus track — which sorts
/// last — would hold the badge at the bottom of the list while unheard
/// episodes sit above it.
///
/// Within a run:
///   1. an episode that is genuinely in progress (recent saved position)
///   2. the first unheard episode after the last heard one
///   3. the first unheard episode
TileItem? pickNextUnheard(
  List<TileItem> episodes, {
  required bool Function(TileItem) isAvailable,
  DateTime? now,
  Duration staleAfter = nextUnheardStaleAfter,
}) {
  final reference = now ?? DateTime.now();

  bool inProgress(TileItem ep) {
    if (ep.lastPositionMs <= 0) return false;
    final playedAt = ep.lastPlayedAt;
    // A saved position always carries a timestamp: savePosition writes both
    // together, clearPositions clears both together, and the two columns
    // arrived in the same migration. So a position without one is not a
    // resumable episode.
    if (playedAt == null) return false;
    return reference.difference(playedAt) < staleAfter;
  }

  final mainRun = <TileItem>[];
  final bonus = <TileItem>[];
  for (final ep in episodes) {
    (isBonusItem(ep) ? bonus : mainRun).add(ep);
  }

  return _pickWithin(mainRun, isAvailable, inProgress) ??
      _pickWithin(bonus, isAvailable, inProgress);
}

TileItem? _pickWithin(
  List<TileItem> episodes,
  bool Function(TileItem) isAvailable,
  bool Function(TileItem) inProgress,
) {
  for (final ep in episodes) {
    if (isAvailable(ep) && inProgress(ep)) return ep;
  }

  final lastHeardIndex = episodes.lastIndexWhere((ep) => ep.isHeard);
  if (lastHeardIndex >= 0) {
    for (var i = lastHeardIndex + 1; i < episodes.length; i++) {
      if (isAvailable(episodes[i])) return episodes[i];
    }
  }

  for (final ep in episodes) {
    if (isAvailable(ep)) return ep;
  }
  return null;
}
