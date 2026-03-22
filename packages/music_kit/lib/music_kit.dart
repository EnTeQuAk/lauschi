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
/// On Android, credentials are read from AndroidManifest metadata
/// (music_kit.teamId, music_kit.keyId, music_kit.key). The plugin
/// generates the developer JWT on-device.
///
/// Playback uses a custom ExoPlayer with Widevine DRM for Apple Music
/// HLS streams. State updates are pushed via EventChannel.
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

  /// Stream of DRM player state updates (push from native ExoPlayer).
  /// Events are maps with:
  ///   {type: "state", isPlaying: bool, positionMs: int, durationMs: int}
  ///   {type: "error", message: String}
  ///   {type: "trackChanged", index: int}
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
}
