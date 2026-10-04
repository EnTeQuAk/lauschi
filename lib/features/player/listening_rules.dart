/// When a played item counts as started and when it counts as finished.
///
/// Pure rules, evaluated by the player at explicit moments (a position
/// save, the kid pausing, the kid moving on). Everything that decides
/// "started" or "finished" lives here, so a rule for particular content
/// (e.g. curated credits lengths from the catalog) has one place to go.
library;

import 'package:lauschi/core/database/app_database.dart';

/// Where playback of an item stands.
typedef PlaybackProgress =
    ({
      /// 1-based number of the current track.
      int trackNumber,

      /// Whether the current track is the item's last one.
      bool isLastTrack,

      /// Position within the current track.
      int positionMs,

      /// Duration of the current track, 0 when unknown.
      int trackDurationMs,

      /// Time from the start of the item to the current position, across
      /// all tracks.
      int elapsedMs,

      /// Duration of the whole item, 0 when the backend doesn't know it.
      int durationMs,
    });

/// How long an item has to play before it counts as started.
///
/// From then on it is the tile's Weiter item and keeps a resume point. A
/// kid poking at an episode for a few seconds moves neither.
const startedAfterPlayTime = Duration(seconds: 20);

/// Share of an item that may be left when it counts as finished.
///
/// Hörspiele often end on a song, an outro and credits that regular
/// listeners skip, up to 6 % of the album in listening data from
/// 2026-09 (Eldrador: a 2 minute song plus a minute of credits). Real
/// early stops left 16 % or more.
const finishedWithinShare = 0.10;

/// Upper bound for [finishedWithinShare] on long items, so a 70 minute
/// album doesn't count as heard with seven minutes of story left.
const finishedWithinAtMost = Duration(minutes: 4);

/// Fallback when the backend doesn't know the item's duration: how
/// close to the end of the last track counts as finished.
const finishedWithinLastTrack = Duration(seconds: 30);

/// Whether an item that played for [playTime] counts as started.
bool isStartedEnough(Duration playTime) => playTime >= startedAfterPlayTime;

/// Whether the kid has heard [item], given where its playback stands.
///
/// [item] is unused today, it is the hook for content-specific rules
/// (e.g. a curated credits length from the catalog).
bool isFinishedEnough(TileItem item, PlaybackProgress progress) {
  if (progress.durationMs > 0) {
    final remainingMs = progress.durationMs - progress.elapsedMs;
    final allowedMs = (progress.durationMs * finishedWithinShare).round();
    final capMs = finishedWithinAtMost.inMilliseconds;
    return remainingMs <= (allowedMs < capMs ? allowedMs : capMs);
  }
  if (!progress.isLastTrack || progress.trackDurationMs <= 0) return false;
  final remainingInTrackMs = progress.trackDurationMs - progress.positionMs;
  return remainingInTrackMs <= finishedWithinLastTrack.inMilliseconds;
}
