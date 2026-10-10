import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/features/player/listening_rules.dart';

/// Where to start playback of a card: the track and the position in it.
typedef ResumeAt = ({String? trackUri, int trackNumber, int positionMs});

/// The resume point stored on [card].
ResumeAt resumeAtOf(db.TileItem card) => (
  trackUri: card.lastTrackUri,
  trackNumber: card.lastTrackNumber,
  positionMs: card.lastPositionMs,
);

/// Where playback of [stored] starts: where [continuing] last was when a
/// recovery replay continues that listen, else the stored resume point.
/// A finish (or a play under 20 s) leaves the stored one empty, so a
/// replay that read it restarted the episode from the top.
ResumeAt startPosition(db.TileItem stored, {PlaySession? continuing}) =>
    continuing?.lastPosition ?? resumeAtOf(stored);

/// One play of one card, from the tap until the next card or a stop.
///
/// Backend states and listening writes belong to a session. A closed
/// session is no longer the player's current one, and everything still
/// arriving on its behalf is dropped.
class PlaySession {
  PlaySession(this.card);

  /// The card as stored when the listen opened. A recovery replay keeps
  /// the session, it is the same listen on a fresh backend.
  final db.TileItem card;

  /// Played long enough to count as started (see [isStartedEnough]).
  bool started = false;

  /// The card is finished. Recorded once, never undone in a session.
  bool finished = false;

  /// The backend's latest state said it reached the end of the card, so
  /// a repeat of that report isn't handled twice.
  bool reachedEnd = false;

  /// The last track and position the backend reported, so a recovery
  /// replay continues there even when the resume point is gone (a card
  /// finished on pause has none).
  ResumeAt? lastPosition;

  final Stopwatch _playStopwatch = Stopwatch();
  Duration _playedBefore = Duration.zero;

  /// Listening writes of this session, one after another, so a resume
  /// point saved just before a finish can never land after it.
  Future<void> _writes = Future.value();

  /// How long audio has actually played in this session.
  Duration get playTime => _playedBefore + _playStopwatch.elapsed;

  /// How much of the item this listen covered (see
  /// `PlaybackProgress.coveredMs`).
  int get coveredMs => card.lastElapsedMs + playTime.inMilliseconds;

  void resumeClock() => _playStopwatch.start();

  void pauseClock() {
    _playedBefore += _playStopwatch.elapsed;
    _playStopwatch
      ..stop()
      ..reset();
  }

  /// Run [write] after every write this session queued before it.
  Future<void> queue(Future<void> Function() write) {
    final next = _writes.then((_) => write());
    _writes = next.catchError((Object _) {});
    return next;
  }
}
