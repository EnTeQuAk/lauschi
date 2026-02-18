import 'dart:async';
import 'dart:convert';

import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_auth.dart';
import 'package:lauschi/core/spotify/spotify_config.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const _tag = 'PlayerBridge';

/// Manages the hidden WebView hosting the Spotify Web Playback SDK.
///
/// Events flow JS → Dart via a `SpotifyBridge` JavaScript channel.
/// Commands flow Dart → JS via `controller.runJavaScript()`.
class SpotifyPlayerBridge {
  final _stateController = StreamController<PlaybackState>.broadcast();

  late final WebViewController controller;
  SpotifyAuth? _auth;
  SpotifyTokens? _tokens;
  PlaybackState _state = const PlaybackState();

  /// Stream of playback state changes.
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Current playback state.
  PlaybackState get currentState => _state;

  /// The WebView widget needs real dimensions (300x300+).
  /// 1x1 causes Android to suspend media playback.
  WebViewController get webViewController => controller;

  /// Initialize the WebView and load the player HTML.
  Future<void> init({
    required SpotifyAuth auth,
    required SpotifyTokens tokens,
  }) async {
    _auth = auth;
    _tokens = tokens;
    Log.info(_tag, 'Initializing WebView bridge');

    controller = WebViewController(
      onPermissionRequest: (request) {
        // Grant PROTECTED_MEDIA_ID so Android WebView exposes Widevine via EME.
        Log.info(_tag, 'Permission request', data: {
          'types': '${request.types.map((t) => t.name).toList()}',
        });
        unawaited(request.grant());
      },
    );

    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);

    // Allow audio playback without user gesture.
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
    }

    // WORKAROUND: Spotify Web Playback SDK checks browser UA before initializing
    // EME/Widevine. Android WebView's default UA fails the SDK's capability gate.
    // TODO: file upstream — Spotify should detect Widevine directly, not via UA.
    const ua = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/144.0.7559.132 Mobile Safari/537.36';
    await controller.setUserAgent(ua);

    await controller.addJavaScriptChannel(
      'SpotifyBridge',
      onMessageReceived: _onMessage,
    );

    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) => Log.info(_tag, 'Player page loaded'),
      onWebResourceError: (err) {
        Log.error(_tag, 'WebView resource error', data: {
          'code': '${err.errorCode}',
          'desc': err.description,
        });
        _updateState(_state.copyWith(error: err.description, isReady: false));
      },
    ));

    Log.info(_tag, 'Loading player HTML');
    await controller.loadRequest(Uri.parse(SpotifyConfig.playerUrl));
  }

  void _onMessage(JavaScriptMessage msg) {
    late final Map<String, dynamic> data;
    try {
      data = json.decode(msg.message) as Map<String, dynamic>;
    } on FormatException {
      Log.error(_tag, 'Invalid JSON from JS', data: {'raw': msg.message});
      return;
    }

    final type = data['type'] as String?;
    final payload = data['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'sdk_ready':
        unawaited(_initPlayer());

      case 'ready':
        final deviceId = payload['device_id'] as String?;
        Log.info(_tag, 'Player ready', data: {'device_id': '$deviceId'});
        _updateState(_state.copyWith(isReady: true, deviceId: deviceId));

      case 'not_ready':
        Log.warn(_tag, 'Player not ready');
        _updateState(_state.copyWith(isReady: false, clearDeviceId: true));

      case 'state_changed':
        _handleStateChanged(payload);

      case 'token_request':
        Log.info(_tag, 'SDK requesting token refresh');
        unawaited(_deliverFreshToken());

      case 'play_request':
        // Legacy — playback is now handled via SpotifyApi, not via JS bridge.
        Log.debug(_tag, 'Play request from JS (ignored)');

      case 'error':
        final errType = payload['type'] as String? ?? 'unknown';
        final errMsg = payload['message'] as String? ?? '';
        Log.error(_tag, 'SDK error', data: {'type': errType, 'message': errMsg});
        _updateState(_state.copyWith(error: '$errType: $errMsg'));

      case 'log':
        Log.debug('js', '${payload['message']}');

      default:
        Log.warn(_tag, 'Unknown event', data: {'type': '$type'});
    }
  }

  void _handleStateChanged(Map<String, dynamic> payload) {
    final paused = payload['paused'] as bool? ?? true;
    final posMs = payload['position_ms'] as int? ?? 0;
    final durMs = payload['duration_ms'] as int? ?? 0;
    final trackData = payload['track'] as Map<String, dynamic>?;

    final track = trackData == null
        ? null
        : TrackInfo(
            uri: trackData['uri'] as String,
            name: trackData['name'] as String,
            artist: trackData['artist'] as String,
            album: trackData['album'] as String,
            artworkUrl: trackData['artwork_url'] as String?,
          );

    _updateState(_state.copyWith(
      isPlaying: !paused,
      positionMs: posMs,
      durationMs: durMs,
      track: track,
    ));
  }

  Future<void> _initPlayer() async {
    if (_tokens == null) return;
    Log.info(_tag, 'Initializing SDK player with token');
    final token = await _freshToken();
    final safeToken = token.replaceAll('"', r'\"');
    await controller.runJavaScript('window.lauschi.init("$safeToken")');
  }

  Future<void> _deliverFreshToken() async {
    if (_tokens == null) return;
    try {
      final token = await _freshToken();
      final safeToken = token.replaceAll('"', r'\"');
      await controller.runJavaScript('window.lauschi.deliver_token("$safeToken")');
    } on Exception catch (e) {
      Log.error(_tag, 'Token delivery failed', exception: e);
      _updateState(_state.copyWith(error: 'Token refresh failed'));
    }
  }

  Future<String> _freshToken() async {
    if (_tokens == null || _auth == null) {
      throw StateError('Bridge not initialized');
    }
    if (!_tokens!.isExpired) return _tokens!.accessToken;

    if (_tokens!.refreshToken == null) {
      throw StateError('Token expired, no refresh token');
    }

    final refreshed = await _auth!.refresh(_tokens!.refreshToken!);
    _tokens = refreshed;
    return refreshed.accessToken;
  }

  void _updateState(PlaybackState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  // ---------------------------------------------------------------------------
  // JS commands (used by player SDK locally, not via Web API)
  // ---------------------------------------------------------------------------

  /// Toggle play/pause via the local SDK player.
  Future<void> togglePlay() async {
    await controller.runJavaScript('window.lauschi.toggle_play()');
  }

  /// Next track via local SDK.
  Future<void> nextTrack() async {
    await controller.runJavaScript('window.lauschi.next_track()');
  }

  /// Previous track via local SDK.
  Future<void> prevTrack() async {
    await controller.runJavaScript('window.lauschi.prev_track()');
  }

  /// Seek to position via local SDK.
  Future<void> seek(int positionMs) async {
    await controller.runJavaScript('window.lauschi.seek($positionMs)');
  }

  /// Disconnect and clean up.
  Future<void> dispose() async {
    Log.info(_tag, 'Disposing bridge');
    await controller.runJavaScript('window.lauschi.disconnect()');
    await _stateController.close();
  }
}
