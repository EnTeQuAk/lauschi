import 'package:flutter/services.dart';
import 'package:music_kit_platform_interface/music_kit_platform_interface.dart';

export 'package:music_kit_platform_interface/music_kit_platform_interface.dart'
    show
        //
        MusicAuthorizationStatus,
        MusicAuthorizationStatusAuthorized,
        MusicAuthorizationStatusDenied,
        MusicAuthorizationStatusNotDetermined,
        MusicAuthorizationStatusRestricted,
        //
        MusicSubscription,
        //
        MusicPlayerState,
        MusicPlayerQueue,
        MusicPlayerQueueEntry,
        MusicPlayerPlaybackStatus,
        MusicPlayerRepeatMode,
        MusicPlayerShuffleMode;

/// Flutter interface to Apple MusicKit.
///
/// On Android, credentials are read from AndroidManifest metadata
/// (music_kit.teamId, music_kit.keyId, music_kit.key). The plugin
/// generates the developer JWT on-device.
///
/// On iOS, MusicKit uses the app's MusicKit capability.
class MusicKit {
  factory MusicKit() {
    _singleton ??= MusicKit._();
    return _singleton!;
  }

  MusicKit._();

  static MusicKit? _singleton;

  static MusicKitPlatform get _platform => MusicKitPlatform.instance;

  // Direct method channel for methods not yet in the platform interface.
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
  /// Creates the native MediaPlayerController for playback.
  Future<void> setMusicUserToken(String token) =>
      _channel.invokeMethod('setMusicUserToken', {'token': token});

  // ── DRM Player State Stream ──────────────────────────────────────

  static const _drmStateChannel = EventChannel(
    'plugins.misi.app/music_kit/drm_player_state',
  );

  /// Stream of DRM player state updates (push from native ExoPlayer).
  /// Replaces position polling. Events are maps with:
  ///   {type: "state", isPlaying: bool, positionMs: int, durationMs: int}
  ///   {type: "error", message: String}
  ///   {type: "trackChanged", index: int}
  Stream<Map<String, dynamic>> get drmPlayerStateStream => _drmStateChannel
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  // ── DRM HLS Player ─────────────────────────────────────────────────

  /// Play an Apple Music HLS stream with Widevine DRM.
  Future<void> playDrmStream({
    required String hlsUrl,
    required String licenseUrl,
    required String developerToken,
    required String musicUserToken,
    String songId = '',
  }) => _channel.invokeMethod('playDrmStream', {
    'hlsUrl': hlsUrl,
    'licenseUrl': licenseUrl,
    'developerToken': developerToken,
    'musicUserToken': musicUserToken,
    'songId': songId,
  });

  Future<void> drmPause() => _channel.invokeMethod('drmPlayerPause');
  Future<void> drmResume() => _channel.invokeMethod('drmPlayerResume');
  Future<void> drmStop() => _channel.invokeMethod('drmPlayerStop');
  Future<void> drmSeek(int positionMs) =>
      _channel.invokeMethod('drmPlayerSeek', {'positionMs': positionMs});

  Stream<MusicSubscription> get onSubscriptionUpdated =>
      _platform.onSubscriptionUpdated;

  // ── Player ─────────────────────────────────────────────────────────

  Future<bool> get isPreparedToPlay => _platform.isPreparedToPlay;

  /// Current playback position in seconds.
  Future<double> get playbackTime => _platform.playbackTime;

  /// Set playback position in seconds (seek).
  Future<void> setPlaybackTime(double time) => _platform.setPlaybackTime(time);

  /// Duration of the current item in seconds.
  Future<double> get currentItemDuration async {
    final resp = await _channel.invokeMethod<double>('currentItemDuration');
    return resp ?? 0;
  }

  Future<MusicPlayerState> get musicPlayerState => _platform.musicPlayerState;

  Stream<MusicPlayerState> get onMusicPlayerStateChanged =>
      _platform.onMusicPlayerStateChanged;

  Future<void> pause() => _platform.pause();

  Future<void> play() => _platform.play();

  Future<void> stop() => _platform.stop();

  Future<void> skipToNextEntry() => _platform.skipToNextEntry();

  Future<void> skipToPreviousEntry() => _platform.skipToPreviousEntry();

  Future<void> setQueue(
    String type, {
    required ResourceObject item,
    bool autoplay = true,
  }) => _channel.invokeMethod('setQueue', {
    'type': type,
    'item': item,
    'autoplay': autoplay,
  });

  Future<void> setQueueWithItems(
    String type, {
    required List<ResourceObject> items,
    int? startingAt,
  }) => _platform.setQueueWithItems(type, items: items, startingAt: startingAt);

  Stream<MusicPlayerQueue> get onPlayerQueueChanged =>
      _platform.onPlayerQueueChanged;

  Future<MusicPlayerRepeatMode> get repeatMode => _platform.repeatMode;

  Future<void> setRepeatMode(MusicPlayerRepeatMode mode) =>
      _platform.setRepeatMode(mode);

  Future<MusicPlayerRepeatMode> toggleRepeatMode() =>
      _platform.toggleRepeatMode();

  Future<MusicPlayerShuffleMode> get shuffleMode => _platform.shuffleMode;

  Future<void> setShuffleMode(MusicPlayerShuffleMode mode) =>
      _platform.setShuffleMode(mode);

  Future<MusicPlayerShuffleMode> toggleShuffleMode() =>
      _platform.toggleShuffleMode();
}
