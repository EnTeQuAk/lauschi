import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/apple_music_backend.dart';
import 'package:lauschi/features/player/player_error.dart';

const _tag = 'AppleMusicDrm';

/// Plays Apple Music content via a custom ExoPlayer in the music_kit plugin
/// on Android.
///
/// Pipeline:
///   1. Resolves song IDs to HLS stream URLs via Apple's webPlayback API
///      (undocumented internal endpoint, same as music.apple.com web player)
///   2. Native ExoPlayer (Kotlin) plays HLS with Widevine DRM
///   3. HLS playlist rewritten: ISO-23001-7 to SAMPLE-AES-CTR + KEYFORMAT
///      + proper PSSH box (Apple's format vs what ExoPlayer expects)
///   4. Custom DRM callback wraps Widevine challenge in Apple's JSON protocol
///
/// Each ExoPlayer instance plays one track. Track index is managed on the
/// Dart side; navigation resolves and plays a new stream per track.
class AppleMusicDrmBackend extends AppleMusicBackend {
  AppleMusicDrmBackend({
    required AppleMusicStreamResolver streamResolver,
    required super.api,
    required super.musicKit,
    required String developerToken,
    required String musicUserToken,
  }) : _streamResolver = streamResolver,
       _developerToken = developerToken,
       _musicUserToken = musicUserToken,
       super(logTag: _tag);

  final AppleMusicStreamResolver _streamResolver;
  final String _developerToken;
  final String _musicUserToken;

  @override
  Future<void> startPlayback({
    required int trackIndex,
    required int positionMs,
  }) async {
    await _playTrackAtIndex(trackIndex, startPositionMs: positionMs);
  }

  // TODO(#231): use ExoPlayer ConcatenatingMediaSource for gapless playback
  @override
  Future<void> advanceToNext() async {
    await _playTrackAtIndex(trackIndex + 1);
  }

  @override
  Future<void> advanceToPrev() async {
    await _playTrackAtIndex(trackIndex - 1);
  }

  @override
  Future<void> resume() => musicKit.drmResume();

  @override
  Future<void> pause() => musicKit.drmPause();

  @override
  Future<void> stop() => musicKit.drmStop();

  @override
  Future<void> seek(int positionMs) async {
    await musicKit.drmSeek(positionMs);
  }

  // ── DRM stream resolution + playback ─────────────────────────────

  Future<void> _playTrackAtIndex(
    int index, {
    int startPositionMs = 0,
  }) async {
    if (index < 0 || index >= tracks.length) return;
    final sw = Stopwatch()..start();

    final track = tracks[index];
    StreamResolution? resolution;
    try {
      resolution = await _streamResolver.resolveStream(track.id);
      Log.info(
        _tag,
        'Stream resolved',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
    } on AppleMusicAuthExpiredException catch (e) {
      Log.warn(
        _tag,
        'Auth expired during stream resolve',
        data: {'error': '$e'},
      );
      emitState(error: PlayerError.appleMusicAuthExpired);
      return;
    }
    if (resolution == null) {
      Log.warn(_tag, 'Could not resolve stream for track ${track.id}');
      emitState(error: PlayerError.playbackFailed);
      return;
    }

    trackIndex = index;
    positionMs = 0;
    updateCurrentTrackInfo();

    Log.info(
      _tag,
      'Starting DRM playback',
      data: {
        'track': track.name,
        'licenseUrl': resolution.licenseUrl.isNotEmpty ? 'yes' : 'no',
      },
    );

    try {
      Log.info(
        _tag,
        'Calling playDrmStream',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
      await musicKit.playDrmStream(
        hlsUrl: resolution.hlsUrl,
        licenseUrl: resolution.licenseUrl,
        developerToken: _developerToken,
        musicUserToken: _musicUserToken,
        songId: track.id,
        startPositionMs: startPositionMs,
      );
      Log.info(
        _tag,
        'playDrmStream returned',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
    } on Exception catch (e) {
      Log.error(_tag, 'DRM playback failed', exception: e);
      isPlaying = false;
      emitState(error: PlayerError.playbackFailed);
    }
  }
}
