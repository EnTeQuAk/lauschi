import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

/// Base class for Apple Music playback on both platforms.
///
/// Handles album track management, EventChannel state subscription,
/// track lifecycle (auto-advance, completion), and state emission.
///
/// Subclasses provide the platform-specific transport layer:
/// - AppleMusicDrmBackend (Android): ExoPlayer + Widevine DRM
/// - AppleMusicNativeBackend (iOS): native MusicKit ApplicationMusicPlayer
abstract class AppleMusicBackend extends PlayerBackend {
  AppleMusicBackend({
    required AppleMusicApi api,
    required this.musicKit,
    required this.logTag,
  }) : _api = api;

  final AppleMusicApi _api;

  @protected
  final MusicKit musicKit;

  @protected
  final String logTag;

  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _stateSub;

  @protected
  TrackInfo? currentTrack;

  @protected
  String? albumArtworkUrl;

  @protected
  int durationMs = 0;

  @protected
  int positionMs = 0;

  @protected
  bool isPlaying = false;

  @protected
  int trackIndex = 0;

  @protected
  final tracks = <AppleMusicTrack>[];

  /// Guards against spurious events during deliberate track transitions.
  /// Set by [nextTrack]/[prevTrack], checked by `trackEnded` and
  /// `trackChanged` handlers to avoid double-advance.
  bool _isAdvancing = false;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  int get currentPositionMs => positionMs;

  @override
  int get currentTrackNumber => trackIndex + 1;

  @override
  bool get hasNextTrack => trackIndex < tracks.length - 1;

  // ── Abstract platform hooks ──────────────────────────────────────

  /// Start playing from the given track index after album setup.
  /// Called once at the end of [play] after tracks are fetched and
  /// the state stream is subscribed.
  Future<void> startPlayback({
    required int trackIndex,
    required int positionMs,
  });

  /// Skip to the next track using platform-specific navigation.
  /// Called inside the [_isAdvancing] guard by [nextTrack].
  Future<void> advanceToNext();

  /// Skip to the previous track using platform-specific navigation.
  /// Called inside the [_isAdvancing] guard by [prevTrack].
  Future<void> advanceToPrev();

  /// Classify a Dart exception from the state stream's onError callback.
  /// Override to provide platform-specific mapping (e.g., iOS maps
  /// PlatformException codes to typed errors).
  @protected
  PlayerError classifyError(Object error) => PlayerError.playbackFailed;

  /// Classify an error event pushed by native code via the EventChannel.
  /// Override to map platform-specific error codes to typed errors.
  /// See TODO(#232) for DRM error code differentiation.
  @protected
  PlayerError classifyEventError({
    required int errorCode,
    required String message,
  }) => PlayerError.playbackFailed;

  // ── Shared implementation ────────────────────────────────────────

  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  }) async {
    currentTrack = trackInfo;
    albumArtworkUrl = trackInfo.artworkUrl;
    Log.info(
      logTag,
      'Playing',
      data: {'albumId': albumId, 'track': '$trackIndex'},
    );

    final albumTracks = await _api.getAlbumTracks(albumId);
    if (albumTracks.isEmpty) {
      Log.warn(logTag, 'No tracks found for album $albumId');
      emitState(error: PlayerError.contentUnavailable);
      return;
    }

    tracks
      ..clear()
      ..addAll(albumTracks);

    // Clamp saved track index to valid range. If the album's track list
    // changed since last listen (tracks removed/reordered), fall back to 0.
    final safeIndex = trackIndex < albumTracks.length ? trackIndex : 0;
    final safePosition = safeIndex == trackIndex ? positionMs : 0;
    this.trackIndex = safeIndex;

    _ensureStateStreamSubscribed();
    await startPlayback(trackIndex: safeIndex, positionMs: safePosition);
  }

  @override
  Future<void> nextTrack() async {
    if (!hasNextTrack || _isAdvancing) return;
    _isAdvancing = true;
    try {
      await advanceToNext();
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> prevTrack() async {
    if (trackIndex <= 0 || _isAdvancing) return;
    _isAdvancing = true;
    try {
      await advanceToPrev();
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> dispose() async {
    await _stateSub?.cancel();
    _stateSub = null;
    await _stateController.close();
  }

  // ── State stream ─────────────────────────────────────────────────

  /// Subscribe to the native EventChannel once. Subsequent calls are
  /// no-ops, avoiding the race that unawaited cancel + re-subscribe
  /// creates (brief window with two native listeners active).
  void _ensureStateStreamSubscribed() {
    if (_stateSub != null) return;
    _stateSub = musicKit.drmPlayerStateStream.listen(
      _onStateEvent,
      onError: (Object error) {
        Log.error(logTag, 'State stream error', data: {'error': '$error'});
        isPlaying = false;
        emitState(error: classifyError(error));
      },
    );
  }

  void _onStateEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'state':
        final playing = event['isPlaying'] as bool? ?? false;
        final posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
        final durMs = (event['durationMs'] as num?)?.toInt() ?? 0;

        isPlaying = playing;
        positionMs = posMs;
        if (durMs > 0) durationMs = durMs;
        emitState();

      case 'trackChanged':
        // Sync track index from the native song ID. On iOS, MusicKit
        // manages the queue and fires trackChanged when the current song
        // changes. On Android (ExoPlayer, single MediaItem), this event
        // either doesn't fire or has no songId, so the null guard exits.
        final songId = event['songId'] as String?;
        if (songId == null) break;

        final newIndex = tracks.indexWhere((t) => t.id == songId);
        if (newIndex != -1 && newIndex != trackIndex) {
          Log.info(
            logTag,
            'Track changed',
            data: {
              'from': '$trackIndex',
              'to': '$newIndex',
              'songId': songId,
            },
          );
          trackIndex = newIndex;
          positionMs = 0;
          updateCurrentTrackInfo();
          emitState();
        }

      case 'trackEnded':
        if (_isAdvancing) break;
        Log.info(
          logTag,
          'Track ended',
          data: {
            'index': '$trackIndex',
            'total': '${tracks.length}',
            'hasNext': '$hasNextTrack',
          },
        );
        if (hasNextTrack) {
          unawaited(nextTrack());
        } else {
          isPlaying = false;
          emitState();
        }

      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        final errorCode = event['errorCode'] as int? ?? 0;
        Log.error(
          logTag,
          'Player error',
          data: {'message': message, 'errorCode': '$errorCode'},
        );
        isPlaying = false;
        emitState(
          error: classifyEventError(
            errorCode: errorCode,
            message: message,
          ),
        );

      default:
        Log.warn(logTag, 'Unknown event type: $type');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────

  /// Update [currentTrack] and [durationMs] from the track at [trackIndex].
  @protected
  void updateCurrentTrackInfo() {
    if (trackIndex < 0 || trackIndex >= tracks.length) return;
    final track = tracks[trackIndex];
    currentTrack = TrackInfo(
      uri: ProviderType.appleMusic.trackUri(track.id),
      name: track.name,
      artist: track.artistName,
      artworkUrl: albumArtworkUrl,
    );
    durationMs = track.durationMs;
  }

  @protected
  void emitState({PlayerError? error}) {
    if (_stateController.isClosed) return;
    _stateController.add(
      PlaybackState(
        isPlaying: isPlaying,
        isReady: true,
        track: currentTrack,
        positionMs: positionMs,
        durationMs: durationMs,
        error: error,
      ),
    );
  }
}
