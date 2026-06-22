import 'package:flutter/services.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/apple_music_backend.dart';
import 'package:lauschi/features/player/player_error.dart';

const _tag = 'AppleMusicNative';

/// Plays Apple Music content via native MusicKit (ApplicationMusicPlayer)
/// on iOS.
///
/// Unlike the Android DRM path, no stream URL resolution or license
/// acquisition is needed. MusicKit handles DRM internally. The full album
/// queue is set once via store IDs; navigation uses native skip methods.
class AppleMusicNativeBackend extends AppleMusicBackend {
  AppleMusicNativeBackend({
    required super.api,
    required super.musicKit,
  }) : super(logTag: _tag);

  @override
  Future<void> startPlayback({
    required int trackIndex,
    required int positionMs,
  }) async {
    final trackIds = tracks.map((t) => t.id).toList();
    try {
      await musicKit.setQueueWithStoreIds(trackIds, startingAt: trackIndex);

      updateCurrentTrackInfo();

      // Seek before play to avoid an audio blip at position 0.
      if (positionMs > 0) {
        await musicKit.nativePrepareToPlay();
        await musicKit.nativeSeek(positionMs / 1000.0);
      }

      await musicKit.nativePlay();

      Log.info(
        _tag,
        'Playback started',
        data: {
          'track': tracks[trackIndex].name,
          'positionMs': '$positionMs',
        },
      );
    } on PlatformException catch (e) {
      Log.error(
        _tag,
        'Playback failed',
        data: {'code': e.code, 'msg': e.message ?? ''},
      );
      emitState(error: _mapPlatformError(e));
    }
  }

  @override
  Future<void> advanceToNext() async {
    try {
      await musicKit.nativeSkipToNext();
    } on PlatformException catch (e) {
      Log.error(_tag, 'Skip to next failed', data: {'error': '${e.message}'});
    }
  }

  @override
  Future<void> advanceToPrev() async {
    try {
      await musicKit.nativeSkipToPrevious();
    } on PlatformException catch (e) {
      Log.error(
        _tag,
        'Skip to previous failed',
        data: {'error': '${e.message}'},
      );
    }
  }

  @override
  Future<void> resume() => musicKit.nativePlay();

  @override
  Future<void> pause() => musicKit.nativePause();

  @override
  Future<void> stop() => musicKit.nativeStop();

  @override
  Future<void> seek(int positionMs) async {
    await musicKit.nativeSeek(positionMs / 1000.0);
  }

  @override
  PlayerError classifyError(Object error) {
    if (error is PlatformException) return _mapPlatformError(error);
    return PlayerError.playbackFailed;
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
