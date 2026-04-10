import 'dart:async';

import 'package:flutter/services.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicNative';

/// Plays Apple Music content via native MusicKit (ApplicationMusicPlayer)
/// on iOS.
///
/// Pipeline:
///   1. Fetches album tracks via AppleMusicApi (catalog REST, shared with Android)
///   2. Sets queue by catalog song IDs (native MusicKit resolves and plays)
///   3. State updates via the same EventChannel as Android (drm_player_state)
///      pushed by a native 2Hz timer in the forked music_kit_darwin plugin
///
/// Unlike the Android DRM path, no stream URL resolution or license
/// acquisition is needed. MusicKit handles DRM internally.
class AppleMusicNativeBackend extends PlayerBackend with AlbumPlayback {
  AppleMusicNativeBackend({
    required AppleMusicApi api,
    required MusicKit musicKit,
  }) : _api = api,
       _musicKit = musicKit;

  final AppleMusicApi _api;
  final MusicKit _musicKit;

  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _stateSub;

  TrackInfo? _currentTrack;
  String? _albumArtworkUrl;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _totalTracks = 0;

  final _tracks = <AppleMusicTrack>[];

  /// Guard against processing trackChanged events during manual skip.
  bool _isAdvancing = false;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  int get currentPositionMs => _positionMs;

  @override
  int get currentTrackNumber => _trackIndex + 1;

  @override
  bool get hasNextTrack => _trackIndex < _totalTracks - 1;

  /// Play an album starting from a track index.
  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  }) async {
    _currentTrack = trackInfo;
    _albumArtworkUrl = trackInfo.artworkUrl;
    Log.info(
      _tag,
      'Playing',
      data: {'albumId': albumId, 'track': '$trackIndex'},
    );

    final tracks = await _api.getAlbumTracks(albumId);
    if (tracks.isEmpty) {
      Log.warn(_tag, 'No tracks found for album $albumId');
      _emitState(error: PlayerError.contentUnavailable);
      return;
    }

    _tracks
      ..clear()
      ..addAll(tracks);
    _totalTracks = tracks.length;

    final safeIndex = trackIndex < tracks.length ? trackIndex : 0;
    final safePosition = safeIndex == trackIndex ? positionMs : 0;
    _trackIndex = safeIndex;

    _listenToStateStream();

    // Set the full album queue once. Navigation uses skip methods.
    final trackIds = tracks.map((t) => t.id).toList();
    try {
      await _musicKit.setQueueWithStoreIds(trackIds, startingAt: safeIndex);

      _updateCurrentTrackInfo();

      // Seek before play to avoid an audio blip at position 0.
      if (safePosition > 0) {
        await _musicKit.nativePrepareToPlay();
        await _musicKit.nativeSeek(safePosition / 1000.0);
      }

      await _musicKit.nativePlay();

      Log.info(
        _tag,
        'Playback started',
        data: {
          'track': _tracks[safeIndex].name,
          'positionMs': '$safePosition',
        },
      );
    } on PlatformException catch (e) {
      Log.error(
        _tag,
        'Playback failed',
        data: {'code': e.code, 'msg': e.message ?? ''},
      );
      _emitState(error: _mapPlatformError(e));
    }
  }

  @override
  Future<void> resume() => _musicKit.nativePlay();

  @override
  Future<void> pause() => _musicKit.nativePause();

  @override
  Future<void> stop() => _musicKit.nativeStop();

  @override
  Future<void> seek(int positionMs) async {
    await _musicKit.nativeSeek(positionMs / 1000.0);
  }

  @override
  Future<void> nextTrack() async {
    if (!hasNextTrack || _isAdvancing) return;
    _isAdvancing = true;
    try {
      await _musicKit.nativeSkipToNext();
      // Don't update _trackIndex here. The native trackChanged event
      // will fire with the new songId, and _onStateEvent handles it.
    } on PlatformException catch (e) {
      Log.error(_tag, 'Skip to next failed', data: {'error': '${e.message}'});
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> prevTrack() async {
    if (_trackIndex <= 0 || _isAdvancing) return;
    _isAdvancing = true;
    try {
      await _musicKit.nativeSkipToPrevious();
    } on PlatformException catch (e) {
      Log.error(
        _tag,
        'Skip to previous failed',
        data: {'error': '${e.message}'},
      );
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

  // ── State stream ────────────────────────────────────────────────────

  void _listenToStateStream() {
    unawaited(_stateSub?.cancel());
    _stateSub = _musicKit.drmPlayerStateStream.listen(
      _onStateEvent,
      onError: (Object error) {
        Log.error(_tag, 'State stream error', data: {'error': '$error'});
      },
    );
  }

  void _onStateEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'state':
        final isPlaying = event['isPlaying'] as bool? ?? false;
        final posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
        final durMs = (event['durationMs'] as num?)?.toInt() ?? 0;

        _isPlaying = isPlaying;
        _positionMs = posMs;
        if (durMs > 0) _durationMs = durMs;
        _emitState();

      case 'trackChanged':
        final songId = event['songId'] as String?;
        if (songId == null) break;

        // Sync _trackIndex from the native song ID.
        final newIndex = _tracks.indexWhere((t) => t.id == songId);
        if (newIndex != -1 && newIndex != _trackIndex) {
          Log.info(
            _tag,
            'Track changed',
            data: {
              'from': '$_trackIndex',
              'to': '$newIndex',
              'songId': songId,
            },
          );
          _trackIndex = newIndex;
          _positionMs = 0;
          _updateCurrentTrackInfo();
          _emitState();
        }

      case 'trackEnded':
        if (_isAdvancing) break;
        Log.info(
          _tag,
          'Playback ended',
          data: {
            'index': '$_trackIndex',
            'total': '$_totalTracks',
            'hasNext': '$hasNextTrack',
          },
        );
        if (hasNextTrack) {
          unawaited(nextTrack());
        } else {
          _isPlaying = false;
          _emitState();
        }

      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        final errorCode = event['errorCode'] as int? ?? 0;
        Log.error(
          _tag,
          'Native player error',
          data: {
            'message': message,
            'errorCode': '$errorCode',
          },
        );
        _isPlaying = false;
        _emitState(error: PlayerError.playbackFailed);

      default:
        Log.warn(_tag, 'Unknown event type: $type');
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  void _updateCurrentTrackInfo() {
    if (_trackIndex < 0 || _trackIndex >= _tracks.length) return;
    final track = _tracks[_trackIndex];
    _currentTrack = TrackInfo(
      uri: ProviderType.appleMusic.trackUri(track.id),
      name: track.name,
      artist: track.artistName,
      artworkUrl: _albumArtworkUrl,
    );
    _durationMs = track.durationMs;
  }

  void _emitState({PlayerError? error}) {
    if (_stateController.isClosed) return;
    _stateController.add(
      PlaybackState(
        isPlaying: _isPlaying,
        isReady: true,
        track: _currentTrack,
        positionMs: _positionMs,
        durationMs: _durationMs,
        error: error,
      ),
    );
  }

  PlayerError _mapPlatformError(PlatformException e) {
    return switch (e.code) {
      'ERR_NOT_AUTHORIZED' => PlayerError.appleMusicAuthExpired,
      'ERR_SUBSCRIPTION_REQUIRED' => PlayerError.appleMusicAuthExpired,
      'ERR_NETWORK' => PlayerError.playbackFailed,
      'ERR_CONTENT_UNAVAILABLE' => PlayerError.contentUnavailable,
      _ => PlayerError.playbackFailed,
    };
  }
}
