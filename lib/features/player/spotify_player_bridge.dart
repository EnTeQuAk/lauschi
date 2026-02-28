import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_config.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const _tag = 'PlayerBridge';

/// Max plausible position/duration (24 hours). Clamps garbage values from SDK.
const _maxPositionMs = 86400000;

/// Max message size from JS bridge. Reject larger payloads.
const _maxMessageBytes = 65536;

/// Ignore backward position jumps smaller than this. The Spotify SDK on iOS
/// sometimes fires events with slightly older positions (buffering noise).
const _positionJitterThresholdMs = 2000;

/// Manages the hidden WebView hosting the Spotify Web Playback SDK.
///
/// Events flow JS → Dart via a `SpotifyBridge` JavaScript channel.
/// Commands flow Dart → JS via `controller.runJavaScript()`.
class SpotifyPlayerBridge {
  final _stateController = StreamController<PlaybackState>.broadcast();

  /// Callback to get a valid (non-expired) access token.
  /// Set in [init], non-null for the lifetime of the bridge after that.
  late final Future<String> Function() _getValidToken;

  bool _disposed = false;
  WebViewController? _controller;

  /// Access the WebView controller. Only available after [init].
  WebViewController get controller {
    final c = _controller;
    if (c == null) throw StateError('Bridge not initialized');
    return c;
  }

  PlaybackState _state = const PlaybackState();

  // Spotify-specific state tracked internally (not on PlaybackState).
  String? _deviceId;
  int _trackNumber = 0;
  int _nextTracksCount = 0;

  /// Stream of playback state changes.
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Current playback state (shared fields only).
  PlaybackState get currentState => _state;

  /// Spotify device ID, or null if not yet connected.
  String? get deviceId => _deviceId;

  /// 1-based track position within the current album.
  int get trackNumber => _trackNumber;

  /// Number of tracks remaining after the current one.
  int get nextTracksCount => _nextTracksCount;

  /// The WebView controller, or null if not yet initialized.
  /// Used by `_WebViewHost` widget to render the hidden WebView.
  WebViewController? get controllerOrNull => _controller;

  /// Initialize the WebView and load the player HTML.
  Future<void> init({
    required Future<String> Function() getValidToken,
  }) async {
    _getValidToken = getValidToken;
    Log.info(_tag, 'Initializing WebView bridge');

    // Platform-specific WebView creation params.
    // iOS WKWebView needs media config at creation time, not after.
    final PlatformWebViewControllerCreationParams params;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      params = WebKitWebViewControllerCreationParams(
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        allowsInlineMediaPlayback: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _controller = WebViewController.fromPlatformCreationParams(
      params,
      onPermissionRequest: (request) {
        // Only grant PROTECTED_MEDIA_ID (Widevine DRM). Reject everything else.
        const allowed = {'protectedMediaId'};
        final requested = request.types.map((t) => t.name).toSet();
        Log.info(
          _tag,
          'Permission request',
          data: {'types': '$requested'},
        );
        if (requested.any(allowed.contains)) {
          unawaited(request.grant());
        } else {
          Log.warn(
            _tag,
            'Rejected permission request',
            data: {'types': '$requested'},
          );
          unawaited(request.deny());
        }
      },
    );

    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);

    // Allow audio playback without user gesture (Android).
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
    }

    // WORKAROUND: Spotify Web Playback SDK checks browser UA before initializing
    // EME/Widevine. The default mobile WebView UAs fail the SDK's capability gate.
    // TODO: file upstream — Spotify should detect DRM directly, not via UA.
    final ua =
        defaultTargetPlatform == TargetPlatform.iOS
            ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                'Version/18.0 Mobile/15E148 Safari/604.1'
            : 'Mozilla/5.0 (Linux; Android 15; Pixel 9) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/144.0.7559.132 Mobile Safari/537.36';
    await controller.setUserAgent(ua);

    await controller.addJavaScriptChannel(
      'SpotifyBridge',
      onMessageReceived: _onMessage,
    );

    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final host = uri?.host ?? '';
          // Allow the player HTML host and Spotify SDK CDN.
          final playerUri = Uri.tryParse(SpotifyConfig.playerUrl);
          final allowed = {
            if (playerUri != null) playerUri.host,
            'sdk.scdn.co',
          };
          if (allowed.contains(host) || request.url == 'about:blank') {
            return NavigationDecision.navigate;
          }
          Log.warn(
            _tag,
            'Blocked navigation',
            data: {'url': request.url},
          );
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) => Log.info(_tag, 'Player page loaded'),
        onWebResourceError: (err) {
          Log.error(
            _tag,
            'WebView resource error',
            data: {
              'code': '${err.errorCode}',
              'desc': err.description,
            },
          );
          _updateState(_state.copyWith(isReady: false));
        },
      ),
    );

    Log.info(_tag, 'Loading player HTML');
    await controller.loadRequest(Uri.parse(SpotifyConfig.playerUrl));
  }

  /// Allowed message types from the JS bridge. Reject anything else to
  /// prevent unexpected payloads if the CDN-loaded SDK is compromised.
  static const _allowedTypes = {
    'sdk_ready',
    'ready',
    'not_ready',
    'state_changed',
    'token_request',
    'error',
    'log',
  };

  void _onMessage(JavaScriptMessage msg) {
    // Reject oversized messages (>64KB is suspicious for our protocol).
    if (msg.message.length > _maxMessageBytes) {
      Log.warn(
        _tag,
        'Dropped oversized message',
        data: {
          'bytes': '${msg.message.length}',
        },
      );
      return;
    }

    late final Map<String, dynamic> data;
    try {
      data = json.decode(msg.message) as Map<String, dynamic>;
    } on FormatException {
      Log.error(
        _tag,
        'Invalid JSON from JS',
        data: {
          'raw':
              msg.message.length > 200
                  ? '${msg.message.substring(0, 200)}…'
                  : msg.message,
        },
      );
      return;
    }

    final type = data['type'] as String?;
    if (type == null || !_allowedTypes.contains(type)) {
      Log.warn(_tag, 'Rejected unknown message type', data: {'type': '$type'});
      return;
    }

    final payload = data['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'sdk_ready':
        unawaited(_initPlayer());

      case 'ready':
        final id = payload['device_id'] as String?;
        if (id != null && id.length > 128) {
          Log.warn(_tag, 'Rejected invalid device_id');
          return;
        }
        Log.info(_tag, 'Player ready', data: {'device_id': '$id'});
        _deviceId = id;
        _updateState(_state.copyWith(isReady: true));

      case 'not_ready':
        Log.warn(_tag, 'Player not ready');
        _deviceId = null;
        _updateState(_state.copyWith(isReady: false));

      case 'state_changed':
        _handleStateChanged(payload);

      case 'token_request':
        Log.info(_tag, 'SDK requesting token refresh');
        unawaited(_deliverFreshToken());

      case 'error':
        final errType = _sanitize(payload['type'] as String? ?? 'unknown');
        final errMsg = _sanitize(payload['message'] as String? ?? '');
        Log.error(
          _tag,
          'SDK error',
          data: {'type': errType, 'message': errMsg},
        );
        _updateState(
          _state.copyWith(error: _classifyError(errType, errMsg)),
        );

      case 'log':
        Log.debug('js', _sanitize('${payload['message']}'));

      default:
        // Unreachable due to allowlist check above, but satisfies exhaustiveness.
        break;
    }
  }

  /// Truncate and strip control characters from JS-originated strings.
  static String _sanitize(String input, {int maxLength = 500}) {
    final clamped =
        input.length > maxLength ? '${input.substring(0, maxLength)}…' : input;
    return clamped.replaceAll(RegExp(r'[\x00-\x1f]'), '');
  }

  void _handleStateChanged(Map<String, dynamic> payload) {
    final paused = payload['paused'] as bool? ?? true;
    final posMs = (payload['position_ms'] as int? ?? 0).clamp(
      0,
      _maxPositionMs,
    );
    final durMs = (payload['duration_ms'] as int? ?? 0).clamp(
      0,
      _maxPositionMs,
    );
    final trackNum = (payload['track_number'] as int? ?? 0).clamp(0, 9999);
    final nextCount = (payload['next_tracks_count'] as int? ?? 0).clamp(
      0,
      9999,
    );
    final trackData = payload['track'] as Map<String, dynamic>?;

    TrackInfo? track;
    if (trackData != null) {
      // Validate required fields before constructing TrackInfo.
      final uri = trackData['uri'] as String?;
      final name = trackData['name'] as String?;
      final artist = trackData['artist'] as String?;
      final album = trackData['album'] as String?;

      if (uri != null && name != null && artist != null && album != null) {
        track = TrackInfo(
          uri: _sanitize(uri, maxLength: 256),
          name: _sanitize(name),
          artist: _sanitize(artist),
          album: _sanitize(album),
          artworkUrl: _sanitize(trackData['artwork_url'] as String? ?? ''),
        );
      }
    }

    // Suppress stale position updates from the Spotify SDK on iOS.
    // The SDK sometimes fires events with slightly older positions,
    // causing the progress bar to jitter (30→31→32→30→31…).
    // Accept the update only if position moves forward, same track is
    // playing, or the track changed (seek/skip).
    final sameTrack =
        track?.uri == _state.track?.uri && trackNum == _trackNumber;
    final positionWentBack = sameTrack && posMs < _state.positionMs;
    // Allow small backward jumps (<2s): rounding/buffering noise.
    // Only suppress larger jumps that cause visible jitter.
    final effectivePos =
        positionWentBack &&
                (_state.positionMs - posMs) < _positionJitterThresholdMs
            ? _state.positionMs
            : posMs;

    // Log track changes and significant state transitions.
    final trackChanged = track?.uri != _state.track?.uri;
    if (trackChanged && track != null) {
      Log.info(
        _tag,
        'Track changed',
        data: {
          'track': track.name,
          'artist': track.artist ?? '',
          'number': '$trackNum',
          'remaining': '$nextCount',
        },
      );
    }

    _trackNumber = trackNum;
    _nextTracksCount = nextCount;

    _updateState(
      _state.copyWith(
        isPlaying: !paused,
        positionMs: effectivePos,
        durationMs: durMs,
        track: track,
      ),
    );
  }

  Future<void> _initPlayer() async {
    Log.info(_tag, 'Initializing SDK player with token');
    final token = await _getValidToken();
    await _runJs('window.lauschi.init(${json.encode(token)})');
  }

  Future<void> _deliverFreshToken() async {
    try {
      final token = await _getValidToken();
      await _runJs(
        'window.lauschi.deliver_token(${json.encode(token)})',
      );
      Log.info(_tag, 'Delivered fresh token to SDK');
    } on Exception catch (e) {
      Log.error(_tag, 'Token delivery failed', exception: e);
      _updateState(
        _state.copyWith(error: PlayerError.spotifyAuthExpired),
      );
    }
  }

  /// Run JS on the WebView, catching PlatformException when the WebView
  /// isn't ready or has been torn down (e.g. app backgrounded on iOS).
  Future<void> _runJs(String js) async {
    if (_disposed || _controller == null) return;
    try {
      // Guard against calls before player.html has defined window.lauschi.
      final guarded = 'if(window.lauschi){$js}';
      await controller.runJavaScript(guarded);
    } on PlatformException catch (e) {
      Log.warn(_tag, 'JS eval failed (WebView not ready?): ${e.code}');
    }
  }

  void _updateState(PlaybackState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  // ---------------------------------------------------------------------------
  // JS commands (used by player SDK locally, not via Web API)
  // ---------------------------------------------------------------------------

  /// Re-register the SDK player with Spotify's servers.
  /// Call when the device_id goes stale (404 on play).
  /// The SDK will fire 'ready' with a new device_id on success.
  Future<void> reconnect() async {
    Log.info(_tag, 'Requesting SDK reconnect');
    // Clear stale device_id BEFORE firing JS. This ensures waitForDevice()
    // actually waits for the fresh 'ready' event instead of returning the
    // stale ID immediately. Order matters: if 'ready' fires between
    // _updateState and _runJs, the new ID lands in state and
    // waitForDevice() picks it up correctly.
    _deviceId = null;
    _updateState(_state.copyWith(isReady: false));
    await _runJs('window.lauschi.reconnect()');
  }

  /// Wait for the device to become ready (up to [timeout]).
  /// Returns the device_id or null if not ready in time.
  Future<String?> waitForDevice({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (_deviceId != null) return _deviceId;

    try {
      await _stateController.stream
          .where((_) => _deviceId != null)
          .first
          .timeout(timeout);
      return _deviceId;
    } on Exception {
      return null;
    }
  }

  /// Pause via the local SDK player (idempotent, safe to call when paused).
  Future<void> pause() async {
    Log.debug(_tag, 'JS: pause');
    await _runJs('window.lauschi.pause()');
  }

  /// Resume via the local SDK player (idempotent — safe to call when playing).
  Future<void> resume() async {
    Log.debug(_tag, 'JS: resume');
    await _runJs('window.lauschi.resume()');
  }

  /// Next track via local SDK.
  Future<void> nextTrack() async {
    Log.debug(_tag, 'JS: next_track');
    await _runJs('window.lauschi.next_track()');
  }

  /// Previous track via local SDK.
  Future<void> prevTrack() async {
    Log.debug(_tag, 'JS: prev_track');
    await _runJs('window.lauschi.prev_track()');
  }

  /// Seek to position via local SDK.
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'JS: seek $positionMs');
    await _runJs('window.lauschi.seek($positionMs)');
  }

  /// Map raw SDK error types to typed error values.
  PlayerError _classifyError(String type, String message) {
    return switch (type) {
      'auth' => PlayerError.spotifyAuthExpired,
      'account' => PlayerError.spotifyAccountError,
      'network' => PlayerError.spotifyNetworkError,
      'playback' => PlayerError.spotifyPlaybackFailed,
      _ when message.contains('Authentication') =>
        PlayerError.spotifyAuthExpired,
      _ when message.contains('network') => PlayerError.spotifyNetworkError,
      _ => PlayerError.spotifyPlaybackFailed,
    };
  }

  /// Disconnect and clean up.
  Future<void> dispose() async {
    _disposed = true;
    Log.info(_tag, 'Disposing bridge');
    try {
      if (_controller != null) {
        await _controller!.runJavaScript('window.lauschi.disconnect()');
      }
    } on Exception catch (e) {
      // WebView may already be destroyed (process killed, widget disposed).
      Log.warn(
        _tag,
        'Disconnect failed (WebView likely dead)',
        data: {'error': '$e'},
      );
    }
    await _stateController.close();
  }
}
