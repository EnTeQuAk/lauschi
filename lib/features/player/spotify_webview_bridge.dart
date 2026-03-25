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
/// Lifecycle (managed by the session provider, not by widgets):
///   [init]     → creates WebView, loads player.html, sets token callback
///   [tearDown] → disconnects SDK, clears controller, keeps StreamController
///   [init]     → can be called again after tearDown (re-login)
///   [dispose]  → permanent shutdown, closes StreamController
///
/// Token callback returns null when auth is unavailable. The bridge
/// handles this gracefully (sets error state, never crashes).
///
/// Events flow JS → Dart via a `SpotifyWebViewBridge` JavaScript channel.
/// Commands flow Dart → JS via `controller.runJavaScript()`.
class SpotifyWebViewBridge {
  final _stateController = StreamController<PlaybackState>.broadcast();

  /// Callback to get a valid (non-expired) access token.
  /// Returns null when auth is unavailable (logged out, refresh failed).
  /// Set in [init], cleared in [tearDown].
  Future<String?> Function()? _getValidToken;

  bool _disposed = false;
  WebViewController? _controller;

  /// True while the player page is reloading after a confirmed process death.
  /// Prevents `_runJs()` from piling on failed calls during reload.
  ///
  /// Note: `_initPlayer` bypasses this guard intentionally. The Spotify SDK
  /// fires `onSpotifyWebPlaybackSDKReady` (sdk_ready) before the browser
  /// fires `onPageFinished`. Blocking init during reload would silently
  /// drop the token delivery, leaving the SDK uninitialized.
  /// See Sentry LAUSCHI-Z (StateError during token callback after logout).
  bool _isReloading = false;

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

  /// The WebView controller, or null if not yet initialized / torn down.
  WebViewController? get controllerOrNull => _controller;

  /// Initialize the WebView and load the player HTML.
  ///
  /// Can be called again after [tearDown] to re-initialize (e.g. after
  /// re-login). Cleans up any previous controller.
  Future<void> init({
    required Future<String?> Function() getValidToken,
  }) async {
    if (_disposed) {
      throw StateError(
        'Cannot init a disposed bridge. '
        'Use tearDown() for recoverable disconnects.',
      );
    }
    _getValidToken = getValidToken;
    Log.info(_tag, 'Initializing WebView bridge');

    // Clean up previous controller if re-initializing after tearDown.
    if (_controller != null) {
      try {
        await _controller!.loadRequest(Uri.parse('about:blank'));
      } on Exception {
        // Controller may be dead from previous lifecycle.
      }
      _controller = null;
    }

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

    final c = _controller!;

    await c.setJavaScriptMode(JavaScriptMode.unrestricted);

    // Allow audio playback without user gesture (Android).
    final platform = c.platform;
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
    await c.setUserAgent(ua);

    await c.addJavaScriptChannel(
      'SpotifyBridge',
      onMessageReceived: _onMessage,
    );

    await c.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          // Allow the player HTML host and Spotify SDK CDN.
          // Block everything else to prevent the WebView from
          // navigating to unexpected URLs.
          final uri = Uri.tryParse(request.url);
          final host = uri?.host ?? '';
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
        onPageFinished: (_) {
          _isReloading = false;
          Log.info(_tag, 'Player page loaded');
        },
        onWebResourceError: (err) {
          Log.error(
            _tag,
            'WebView resource error',
            data: {
              'code': '${err.errorCode}',
              'type': '${err.errorType}',
              'desc': err.description,
            },
          );
          if (err.errorType ==
              WebResourceErrorType.webContentProcessTerminated) {
            // iOS killed the web content process. The WKWebView object
            // is still valid; reload to restart the content process and
            // re-initialize the SDK.
            Log.warn(_tag, 'Content process terminated, reloading');
            _deviceId = null;
            _updateState(_state.copyWith(isReady: false));
            unawaited(_reloadPage());
          } else {
            // Non-termination error (network, etc.). If we're mid-reload,
            // onPageFinished won't fire, so clear _isReloading to avoid
            // permanently blocking JS commands.
            _isReloading = false;
            _updateState(_state.copyWith(isReady: false));
          }
        },
      ),
    );

    Log.info(_tag, 'Loading player HTML');
    await c.loadRequest(Uri.parse(SpotifyConfig.playerUrl));
  }

  /// Disconnect the SDK and release the WebView controller.
  ///
  /// Unlike [dispose], the bridge can be re-initialized via [init] after
  /// this call. The [stateStream] stays open so subscribers (PlayerNotifier)
  /// keep receiving state updates across login/logout cycles.
  ///
  /// Called by the session provider when auth is lost.
  void tearDown() {
    if (_disposed) return;
    Log.info(_tag, 'Tearing down bridge');
    _deviceId = null;
    _trackNumber = 0;
    _nextTracksCount = 0;
    _getValidToken = null;
    _isReloading = false;

    // Capture controller reference before nulling. _runJs is async
    // and reads _controller; nulling it first would silently drop
    // the disconnect call.
    final controller = _controller;
    _controller = null;

    if (controller != null) {
      // Disconnect SDK and blank out the page. Fire-and-forget because
      // the controller may already be dead (iOS process termination).
      try {
        unawaited(
          controller
              .runJavaScript(
                'if(window.lauschi){window.lauschi.disconnect()}',
              )
              .catchError((_) {}),
        );
      } on Exception {
        // Controller may be dead already.
      }
      unawaited(
        controller.loadRequest(Uri.parse('about:blank')).catchError((_) {}),
      );
    }

    _updateState(const PlaybackState());
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
    // Reject messages after disposal or teardown. _getValidToken is
    // null between tearDown and the next init, meaning no active session.
    if (_disposed || _getValidToken == null) return;

    if (msg.message.length > _maxMessageBytes) {
      Log.warn(
        _tag,
        'Dropped oversized message',
        data: {'bytes': '${msg.message.length}'},
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
        break;
    }
  }

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
    // causing the progress bar to jitter (30→31→32→30→31...).
    // Accept the update only if position moves forward, the track
    // changed (seek/skip), or the jump is larger than the threshold
    // (real seek backward).
    final sameTrack =
        track?.uri == _state.track?.uri && trackNum == _trackNumber;
    final positionWentBack = sameTrack && posMs < _state.positionMs;
    final effectivePos =
        positionWentBack &&
                (_state.positionMs - posMs) < _positionJitterThresholdMs
            ? _state.positionMs
            : posMs;

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

  /// Initialize the Spotify SDK player with an access token.
  ///
  /// Called when the SDK fires `sdk_ready` after the page loads. Bypasses
  /// the `_isReloading` guard: the Spotify SDK fires
  /// `onSpotifyWebPlaybackSDKReady` before the browser fires
  /// `onPageFinished`, so `_isReloading` is still true during page
  /// reloads. Using `_runJs` here would silently drop the init call,
  /// leaving the SDK uninitialized.
  /// See Sentry LAUSCHI-Z (StateError during token callback after logout).
  Future<void> _initPlayer() async {
    Log.info(_tag, 'Initializing SDK player with token');

    final getToken = _getValidToken;
    if (getToken == null) {
      Log.warn(_tag, 'Init skipped: bridge torn down');
      return;
    }

    String? token;
    try {
      token = await getToken();
    } on Exception catch (e) {
      // Token failure leaves the SDK in a half-initialized state.
      // A full page reload would trigger another sdk_ready, but if
      // auth is genuinely gone, that just loops. Surface the error
      // and let the session handle recovery (re-login → new init).
      Log.warn(_tag, 'Token unavailable for SDK init', data: {'error': '$e'});
      _updateState(_state.copyWith(error: PlayerError.spotifyAuthExpired));
      return;
    }

    if (token == null) {
      Log.warn(_tag, 'Init skipped: not authenticated');
      _updateState(_state.copyWith(error: PlayerError.spotifyAuthExpired));
      return;
    }

    // Direct controller call, bypassing _runJs's _isReloading guard.
    // sdk_ready fires before onPageFinished; that's expected browser
    // behavior for inline scripts.
    if (_controller == null) return;
    try {
      await _controller!.runJavaScript(
        'if(window.lauschi){window.lauschi.init(${json.encode(token)})}',
      );
    } on Exception catch (e) {
      final detail = e is PlatformException ? 'WebView error: ${e.code}' : '$e';
      Log.warn(_tag, 'Init JS failed: $detail');
    }
  }

  /// Deliver a fresh token when the SDK requests one (token expired
  /// during playback).
  Future<void> _deliverFreshToken() async {
    final getToken = _getValidToken;
    if (getToken == null) {
      Log.warn(_tag, 'Token delivery skipped: bridge torn down');
      _updateState(_state.copyWith(error: PlayerError.spotifyAuthExpired));
      return;
    }

    try {
      final token = await getToken();
      if (token == null) {
        Log.warn(_tag, 'Token delivery failed: not authenticated');
        _updateState(_state.copyWith(error: PlayerError.spotifyAuthExpired));
        return;
      }
      await _runJs('window.lauschi.deliver_token(${json.encode(token)})');
      Log.info(_tag, 'Delivered fresh token to SDK');
    } on Exception catch (e) {
      Log.error(_tag, 'Token delivery failed', exception: e);
      _updateState(_state.copyWith(error: PlayerError.spotifyAuthExpired));
    }
  }

  /// Run JS on the WebView, catching PlatformException when the WebView
  /// isn't ready or has been torn down (e.g. app backgrounded on iOS).
  ///
  /// Returns true if JS executed successfully, false if the WebView
  /// content process is dead, suspended, or the controller is unavailable.
  ///
  /// Does NOT clear _deviceId or isReady on failure. Process death is
  /// handled by the WebResourceError callback which triggers _reloadPage.
  Future<bool> _runJs(String js) async {
    if (_disposed || _controller == null) return false;
    if (_isReloading) return false;
    try {
      final guarded = 'if(window.lauschi){$js}';
      await _controller!.runJavaScript(guarded);
      return true;
    } on Exception catch (e) {
      final detail =
          e is PlatformException ? 'WebView likely dead: ${e.code}' : '$e';
      Log.warn(_tag, 'JS eval failed: $detail');
      return false;
    }
  }

  /// Run JS and capture the return value as a string. Returns null on failure.
  Future<String?> _runJsReturning(String js) async {
    if (_disposed || _controller == null) return null;
    if (_isReloading) return null;
    try {
      final guarded = '(function(){if(window.lauschi){return $js}})()';
      final result = await _controller!.runJavaScriptReturningResult(guarded);
      return result.toString();
    } on Exception catch (e) {
      final detail =
          e is PlatformException ? 'WebView likely dead: ${e.code}' : '$e';
      Log.warn(_tag, 'JS eval failed: $detail');
      return null;
    }
  }

  void _updateState(PlaybackState newState) {
    if (_stateController.isClosed) return;
    _state = newState;
    _stateController.add(newState);
  }

  // ---------------------------------------------------------------------------
  // JS commands
  // ---------------------------------------------------------------------------

  /// Re-register the SDK player with Spotify's servers.
  /// Call when the device_id goes stale (404 on play).
  ///
  /// Clears deviceId before sending the JS command. If cleared after,
  /// a concurrent waitForDevice() call could pick up the stale ID
  /// between the JS call and the clear.
  Future<void> reconnect() async {
    Log.info(_tag, 'Requesting SDK reconnect');
    _deviceId = null;
    _updateState(_state.copyWith(isReady: false));

    // reconnect() returns false if SpotifyBridge JS channel is gone
    // (WebView process killed by OS during Apple Music DRM playback).
    // In that case, _runJsReturning returns 'false' and we reload.
    final result = await _runJsReturning('window.lauschi.reconnect()');
    final succeeded = result != null && result != 'false' && result != 'null';
    if (!succeeded && !_isReloading) {
      Log.info(_tag, 'Reconnect failed (JS channel lost), reloading page');
      await _reloadPage();
    }
  }

  /// Full page reload: re-fetch player.html and re-initialize the SDK.
  ///
  /// Used after iOS kills the web content process (WKWebView
  /// webContentProcessTerminated) or when reconnect() fails. Sets
  /// _isReloading to prevent _runJs from piling on failed calls
  /// while the page loads. Cleared by onPageFinished.
  Future<void> _reloadPage() async {
    if (_disposed || _controller == null) return;
    _isReloading = true;
    Log.info(_tag, 'Reloading player page');
    try {
      await _controller!.loadRequest(Uri.parse(SpotifyConfig.playerUrl));
    } on Exception catch (e) {
      _isReloading = false;
      Log.error(_tag, 'Page reload failed', exception: e);
    }
  }

  /// Wait for the device to become ready (up to [timeout]).
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

  Future<void> pause() async {
    Log.debug(_tag, 'JS: pause');
    await _runJs('window.lauschi.pause()');
  }

  Future<void> resume() async {
    Log.debug(_tag, 'JS: resume');
    await _runJs('window.lauschi.resume()');
  }

  Future<void> nextTrack() async {
    Log.debug(_tag, 'JS: next_track');
    await _runJs('window.lauschi.next_track()');
  }

  Future<void> prevTrack() async {
    Log.debug(_tag, 'JS: prev_track');
    await _runJs('window.lauschi.prev_track()');
  }

  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'JS: seek $positionMs');
    await _runJs('window.lauschi.seek($positionMs)');
  }

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

  /// Permanently shut down the bridge. Closes [stateStream].
  /// After dispose, the bridge cannot be reused. Use [tearDown] for
  /// recoverable disconnects.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Log.info(_tag, 'Disposing bridge');
    _getValidToken = null;
    try {
      if (_controller != null) {
        await _controller!.runJavaScript('window.lauschi.disconnect()');
      }
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'Disconnect failed (WebView likely dead)',
        data: {'error': '$e'},
      );
    }
    _controller = null;
    await _stateController.close();
  }
}
