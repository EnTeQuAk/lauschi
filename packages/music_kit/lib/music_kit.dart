import 'package:flutter/services.dart';
import 'package:music_kit_platform_interface/music_kit_platform_interface.dart';

export 'package:music_kit_platform_interface/music_kit_platform_interface.dart'
    show
        MusicAuthorizationStatus,
        MusicAuthorizationStatusAuthorized,
        MusicAuthorizationStatusDenied,
        MusicAuthorizationStatusNotDetermined,
        MusicAuthorizationStatusRestricted,
        MusicSubscription;

/// Flutter interface to Apple MusicKit.
///
/// Two playback paths, same EventChannel format:
///
/// **Android:** Custom ExoPlayer with Widevine DRM. Streams resolved via
/// Apple's webPlayback API. Methods: playDrmStream, drmPause, drmResume, etc.
///
/// **iOS:** Native ApplicationMusicPlayer via MusicKit framework. Queue set
/// by catalog IDs. Methods: nativePlay, nativePause, setQueueWithStoreIds, etc.
///
/// Both push state via `drm_player_state` EventChannel:
///   {type: "state", isPlaying, positionMs, durationMs}
///   {type: "trackChanged", songId}
///   {type: "trackEnded"}
///   {type: "error", message, errorCode}
class MusicKit {
  factory MusicKit() {
    _singleton ??= MusicKit._();
    return _singleton!;
  }

  MusicKit._();

  static MusicKit? _singleton;

  static MusicKitPlatform get _platform => MusicKitPlatform.instance;

  static const _channel = MethodChannel('plugins.misi.app/music_kit');

  // ── Auth ───────────────────────────────────────────────────────────

  Future<MusicAuthorizationStatus> requestAuthorizationStatus({
    String? startScreenMessage,
  }) => _platform.requestAuthorizationStatus(
    startScreenMessage: startScreenMessage,
  );

  Future<MusicAuthorizationStatus> get authorizationStatus =>
      _platform.authorizationStatus;

  Future<String> requestDeveloperToken() => _platform.requestDeveloperToken();

  Future<String> requestUserToken(
    String developerToken, {
    String? startScreenMessage,
  }) => _platform.requestUserToken(
    developerToken,
    startScreenMessage: startScreenMessage,
  );

  Future<String> get currentCountryCode => _platform.currentCountryCode;

  /// Set the music user token directly (e.g. from web auth flow).
  Future<void> setMusicUserToken(String token) =>
      _channel.invokeMethod('setMusicUserToken', {'token': token});

  Stream<MusicSubscription> get onSubscriptionUpdated =>
      _platform.onSubscriptionUpdated;

  // ── DRM Player State Stream ──────────────────────────────────────

  static const _drmStateChannel = EventChannel(
    'plugins.misi.app/music_kit/drm_player_state',
  );

  /// Stream of playback state updates (push from native player).
  /// Events are maps with:
  ///   {type: "state", isPlaying: bool, positionMs: int, durationMs: int}
  ///   {type: "error", message: String, errorCode: int}
  ///   {type: "trackChanged", songId: String}
  ///   {type: "trackEnded"}
  Stream<Map<String, dynamic>> get drmPlayerStateStream => _drmStateChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  // ── DRM HLS Playback ───────────────────────────────────────────────

  /// Play an Apple Music HLS stream with Widevine DRM.
  Future<void> playDrmStream({
    required String hlsUrl,
    required String licenseUrl,
    required String developerToken,
    required String musicUserToken,
    String songId = '',
    int startPositionMs = 0,
  }) => _channel.invokeMethod('playDrmStream', {
    'hlsUrl': hlsUrl,
    'licenseUrl': licenseUrl,
    'developerToken': developerToken,
    'musicUserToken': musicUserToken,
    'songId': songId,
    'startPositionMs': startPositionMs,
  });

  Future<void> drmPause() => _channel.invokeMethod('drmPlayerPause');
  Future<void> drmResume() => _channel.invokeMethod('drmPlayerResume');
  Future<void> drmStop() => _channel.invokeMethod('drmPlayerStop');
  Future<void> drmSeek(int positionMs) =>
      _channel.invokeMethod('drmPlayerSeek', {'positionMs': positionMs});

  // ── Native MusicKit Playback (iOS) ────────────────────────────────

  /// Play via native ApplicationMusicPlayer. Delegates to upstream
  /// music_kit_darwin methods (play/pause/stop/skip/seek/queue).

  Future<void> nativePlay() => _platform.play();
  Future<void> nativePause() => _platform.pause();
  Future<void> nativeStop() => _platform.stop();
  Future<void> nativePrepareToPlay() => _platform.prepareToPlay();
  Future<void> nativeSkipToNext() => _platform.skipToNextEntry();
  Future<void> nativeSkipToPrevious() => _platform.skipToPreviousEntry();

  /// Seek to position in seconds. Added to forked music_kit_darwin.
  Future<void> nativeSeek(double timeInSeconds) =>
      _platform.setPlaybackTime(timeInSeconds);

  /// Current playback position in seconds.
  Future<double> get nativePlaybackTime => _platform.playbackTime;

  /// Set queue by Apple Music catalog song IDs.
  /// Songs are fetched from the catalog and ordered to match [ids].
  /// [startingAt] is the 0-based index of the track to start from.
  Future<void> setQueueWithStoreIds(List<String> ids, {int? startingAt}) =>
      _channel.invokeMethod('setQueueWithStoreIds', {
        'ids': ids,
        'startingAt': startingAt,
      });
}
