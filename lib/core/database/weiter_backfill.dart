/// One-time backfill of `Groups.weiterItemId` for the schema 14 upgrade.
///
/// Before schema 14 the app derived the Weiter item on every read from
/// heard flags and saved positions. The upgrade runs that derivation once
/// per tile and stores the result, so a kid's badge stays where it was.
/// The rules below are frozen as they shipped up to schema 13: don't
/// change them, they describe old data, not current behaviour.
library;

import 'package:lauschi/core/database/app_database.dart';

/// How long a saved position counted as "in progress" before schema 14.
const _staleAfter = Duration(hours: 24);

/// The Weiter item the app showed before schema 14, or null when every
/// item was heard or unavailable (the badge was hidden then, and a null
/// id now means "start at the first item").
TileItem? legacyWeiterFor(List<TileItem> episodes, {required DateTime now}) {
  bool isAvailable(TileItem ep) => !ep.isHeard && ep.markedUnavailable == null;

  DateTime? resumeAt(TileItem ep) {
    if (ep.lastPositionMs <= 0) return null;
    final playedAt = ep.lastPlayedAt;
    if (playedAt == null) return null;
    return now.difference(playedAt) < _staleAfter ? playedAt : null;
  }

  bool isBonus(TileItem ep) => ep.sortOrder == null && ep.episodeNumber == null;

  TileItem? pickWithin(List<TileItem> run) {
    TileItem? freshest;
    DateTime? freshestAt;
    for (final ep in run) {
      final at = resumeAt(ep);
      if (at == null || !isAvailable(ep)) continue;
      if (freshestAt == null || at.isAfter(freshestAt)) {
        freshest = ep;
        freshestAt = at;
      }
    }
    if (freshest != null) return freshest;

    final lastHeardIndex = run.lastIndexWhere((ep) => ep.isHeard);
    for (var i = lastHeardIndex + 1; i < run.length; i++) {
      if (isAvailable(run[i])) return run[i];
    }
    for (final ep in run) {
      if (isAvailable(ep)) return ep;
    }
    return null;
  }

  final mainRun = episodes.where((ep) => !isBonus(ep)).toList();
  final bonus = episodes.where(isBonus).toList();
  return pickWithin(mainRun) ?? pickWithin(bonus);
}
