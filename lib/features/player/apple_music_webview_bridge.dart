import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:lauschi/core/apple_music/apple_music_config.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const _tag = 'AppleMusicBridge';

/// Max plausible position/duration (24 hours). Clamps garbage values.
const _maxPositionMs = 86400000;

/// Max message size from JS bridge.
const _maxMessageBytes = 65536;

/// Manages the hidden WebView hosting MusicKit JS for Apple Music playback.
///
/// Same architecture as `SpotifyWebViewBridge`: a hidden WebView loads
/// apple_music_player.html which includes MusicKit JS v3. Auth tokens
/// (developer + user) are injected from native MusicKit auth, bypassing
/// the JS authorize() popup.
///
/// Lifecycle (managed by AppleMusicSession):
///   [init]     → creates WebView, loads player HTML, waits for sdk_ready
///   [tearDown] → disconnects MusicKit JS, clears controller
///   [init]     → can be called again after tearDown (re-auth)
///   [dispose]  → permanent shutdown
class AppleMusicWebViewBridge {
  final _stateController = StreamController<PlaybackState>.broadcast();

  bool _disposed = false;
  WebViewController? _controller;
  bool _isReloading = false;

  PlaybackState _state = const PlaybackState();

  // Track info tracked internally.
  int _trackIndex = 0;
  int _totalTracks = 0;

  /// Tokens from native MusicKit auth, set by [init].
  String? _developerToken;
  String? _musicUserToken;

  /// Stream of playback state changes.
  Stream<PlaybackState> get stateStream => _stateController.stream;

  /// Current playback state.
  PlaybackState get currentState => _state;

  /// 0-based track index within the current album.
  int get trackIndex => _trackIndex;

  /// Total tracks in the current queue.
  int get totalTracks => _totalTracks;

  /// Whether there are more tracks after the current one.
  bool get hasNextTrack => _trackIndex < _totalTracks - 1;

  /// The WebView controller, or null if not initialized.
  WebViewController? get controllerOrNull => _controller;

  /// Initialize the WebView and load the Apple Music player HTML.
  Future<void> init({
    required String developerToken,
    String? musicUserToken,
  }) async {
    if (_disposed) {
      throw StateError('Cannot init a disposed bridge.');
    }
    _developerToken = developerToken;
    _musicUserToken = musicUserToken;
    Log.info(_tag, 'Initializing WebView bridge');

    // Clean up previous controller if re-initializing.
    if (_controller != null) {
      try {
        await _controller!.loadRequest(Uri.parse('about:blank'));
      } on Exception {
        // Controller may be dead.
      }
      _controller = null;
    }

    // Platform-specific params.
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
        // Grant protectedMediaId (Widevine DRM).
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

    // Android WebView settings needed for MusicKit JS.
    // The AndroidWebViewController constructor already enables DOM storage
    // and JS window opening. But third-party cookies are OFF by default
    // (unlike Chrome). MusicKit JS needs cookies across Apple's domains
    // for DRM content resolution. Without this, setQueue() returns
    // NOT_FOUND even though the catalog API works fine.
    final platform = c.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);

      // Enable third-party cookies for cross-domain DRM/content resolution.
      final cookieManager = AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      );
      await cookieManager.setAcceptThirdPartyCookies(platform, true);

      // Set the media-user-token cookie on Apple's domains.
      // When music.apple.com works in Chrome, this cookie is set during
      // Apple's web auth flow. In our WebView, auth happens natively
      // (no Apple web pages visited), so the cookie doesn't exist.
      // MusicKit JS's setQueue() internally relies on this cookie for
      // content/DRM resolution, even though the API uses Authorization
      // headers. Without it, setQueue returns NOT_FOUND.
      if (_musicUserToken != null) {
        final token = _musicUserToken!;
        const domains = [
          'https://music.apple.com',
          'https://api.music.apple.com',
          'https://play.music.apple.com',
          'https://buy.music.apple.com',
        ];
        for (final domain in domains) {
          await cookieManager.setCookie(
            WebViewCookie(
              name: 'media-user-token',
              value: token,
              domain: domain,
            ),
          );
        }
        Log.info(
          _tag,
          'Set media-user-token cookie on Apple domains',
        );
      }
    }

    // Standard Chrome UA. MusicKit JS may check browser capabilities.
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
      'AppleMusicBridge',
      onMessageReceived: _onMessage,
    );

    await c.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final host = uri?.host ?? '';
          final playerUri = Uri.tryParse(AppleMusicConfig.playerUrl);

          // Allow our player host and all Apple domains.
          // MusicKit JS needs access to multiple Apple subdomains for
          // DRM handshake, streaming, API, and auth. Blocking any of
          // them causes CONTENT_EQUIVALENT errors.
          final isPlayerHost = playerUri != null && host == playerUri.host;
          final isAppleDomain =
              host.endsWith('.apple.com') ||
              host.endsWith('.mzstatic.com') ||
              host.endsWith('.apple-cloudkit.com');

          if (isPlayerHost || isAppleDomain || request.url == 'about:blank') {
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
            Log.warn(_tag, 'Content process terminated, reloading');
            _updateState(_state.copyWith(isReady: false));
            unawaited(_reloadPage());
          } else {
            _isReloading = false;
            _updateState(_state.copyWith(isReady: false));
          }
        },
      ),
    );

    Log.info(_tag, 'Loading Apple Music player HTML');
    await c.loadRequest(Uri.parse(AppleMusicConfig.playerUrl));
  }

  /// Tear down the bridge. Can be re-initialized via [init].
  void tearDown() {
    if (_disposed) return;
    Log.info(_tag, 'Tearing down bridge');
    _trackIndex = 0;
    _totalTracks = 0;
    _developerToken = null;
    _musicUserToken = null;
    _isReloading = false;

    final controller = _controller;
    _controller = null;

    if (controller != null) {
      try {
        unawaited(
          controller
              .runJavaScript(
                'if(window.lauschi){window.lauschi.disconnect()}',
              )
              .catchError((_) {}),
        );
      } on Exception {
        // Controller may be dead.
      }
      unawaited(
        controller.loadRequest(Uri.parse('about:blank')).catchError((_) {}),
      );
    }

    _updateState(const PlaybackState());
  }

  // ---------------------------------------------------------------------------
  // Message handling
  // ---------------------------------------------------------------------------

  static const _allowedTypes = {
    'sdk_ready',
    'ready',
    'needs_auth',
    'state_changed',
    'track_changed',
    'position',
    'auth_status',
    'error',
    'log',
  };

  void _onMessage(JavaScriptMessage msg) {
    if (_disposed || _developerToken == null) return;

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
        final authorized = payload['is_authorized'] as bool? ?? false;
        Log.info(
          _tag,
          'MusicKit JS ready',
          data: {'authorized': '$authorized'},
        );
        _updateState(_state.copyWith(isReady: true));

      case 'needs_auth':
        // MusicKit JS needs web auth. The WebView will redirect to
        // Apple's login page. In a future iteration, Dart should
        // temporarily show the WebView so the user can sign in.
        Log.info(_tag, 'MusicKit JS needs web authorization');

      case 'state_changed':
        _handleStateChanged(payload);

      case 'track_changed':
        _handleTrackChanged(payload);

      case 'position':
        _handlePosition(payload);

      case 'auth_status':
        final authorized = payload['is_authorized'] as bool? ?? false;
        Log.info(
          _tag,
          'Auth status changed',
          data: {'authorized': '$authorized'},
        );
        if (!authorized) {
          _updateState(
            _state.copyWith(error: PlayerError.appleMusicAuthExpired),
          );
        }

      case 'error':
        final errType = _sanitize(payload['type'] as String? ?? 'unknown');
        final errMsg = _sanitize(payload['message'] as String? ?? '');
        Log.error(
          _tag,
          'MusicKit JS error',
          data: {'type': errType, 'message': errMsg},
        );
        _updateState(
          _state.copyWith(error: _classifyError(errType, errMsg)),
        );

      case 'log':
        Log.debug('apple_music_js', _sanitize('${payload['message']}'));

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
    final isPlaying = payload['is_playing'] as bool? ?? false;
    final posMs = (payload['position_ms'] as num? ?? 0).toInt().clamp(
      0,
      _maxPositionMs,
    );
    final durMs = (payload['duration_ms'] as num? ?? 0).toInt().clamp(
      0,
      _maxPositionMs,
    );

    _updateState(
      _state.copyWith(
        isPlaying: isPlaying,
        positionMs: posMs,
        durationMs: durMs,
      ),
    );
  }

  void _handleTrackChanged(Map<String, dynamic> payload) {
    final trackData = payload['track'] as Map<String, dynamic>?;
    final trackIdx = (payload['track_index'] as num? ?? 0).toInt().clamp(
      0,
      9999,
    );
    final total = (payload['total_tracks'] as num? ?? 0).toInt().clamp(0, 9999);

    _trackIndex = trackIdx;
    _totalTracks = total;

    TrackInfo? track;
    if (trackData != null) {
      final id = trackData['id'] as String?;
      final name = trackData['name'] as String?;
      final artist = trackData['artist'] as String?;
      final album = trackData['album'] as String?;
      final durationMs = (trackData['duration_ms'] as num? ?? 0).toInt();

      if (id != null && name != null) {
        track = TrackInfo(
          uri: 'apple_music:track:$id',
          name: _sanitize(name),
          artist: artist != null ? _sanitize(artist) : null,
          album: album != null ? _sanitize(album) : null,
          artworkUrl: _sanitize(trackData['artwork_url'] as String? ?? ''),
        );

        Log.info(
          _tag,
          'Track changed',
          data: {
            'track': name,
            'artist': artist ?? '',
            'index': '$trackIdx',
            'total': '$total',
          },
        );

        // Update duration from track metadata if we have it.
        if (durationMs > 0) {
          _updateState(
            _state.copyWith(track: track, durationMs: durationMs),
          );
          return;
        }
      }
    }

    _updateState(_state.copyWith(track: track));
  }

  void _handlePosition(Map<String, dynamic> payload) {
    final posMs = (payload['position_ms'] as num? ?? 0).toInt().clamp(
      0,
      _maxPositionMs,
    );
    final durMs = (payload['duration_ms'] as num? ?? 0).toInt().clamp(
      0,
      _maxPositionMs,
    );

    _updateState(_state.copyWith(positionMs: posMs, durationMs: durMs));
  }

  /// Initialize MusicKit JS with tokens from native auth.
  ///
  /// Called when MusicKit JS fires 'musickitloaded' (sdk_ready).
  /// Bypasses _isReloading guard: same reason as Spotify (SDK ready
  /// fires before onPageFinished).
  Future<void> _initPlayer() async {
    Log.info(_tag, 'Initializing MusicKit JS');

    final devToken = _developerToken;
    if (devToken == null) {
      Log.warn(_tag, 'Init skipped: developer token unavailable');
      _updateState(
        _state.copyWith(error: PlayerError.appleMusicAuthExpired),
      );
      return;
    }

    if (_controller == null) return;
    try {
      // Pass only the developer token. User auth happens in MusicKit JS
      // via its own authorize() flow (redirect-based in WebViews).
      await _controller!.runJavaScript(
        'if(window.lauschi){window.lauschi.init('
        '${json.encode(devToken)}'
        ')}',
      );
    } on Exception catch (e) {
      final detail = e is PlatformException ? 'WebView error: ${e.code}' : '$e';
      Log.warn(_tag, 'Init JS failed: $detail');
    }
  }

  /// Run JS on the WebView, catching errors.
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

  void _updateState(PlaybackState newState) {
    if (_stateController.isClosed) return;
    _state = newState;
    _stateController.add(newState);
  }

  Future<void> _reloadPage() async {
    if (_disposed || _controller == null) return;
    _isReloading = true;
    Log.info(_tag, 'Reloading player page');
    try {
      await _controller!.loadRequest(Uri.parse(AppleMusicConfig.playerUrl));
    } on Exception catch (e) {
      _isReloading = false;
      Log.error(_tag, 'Page reload failed', exception: e);
    }
  }

  // ---------------------------------------------------------------------------
  // JS commands
  // ---------------------------------------------------------------------------

  /// Play an album starting from a track index.
  /// Storefront defaults to 'de' for DACH market.
  Future<void> playAlbum(
    String albumId, {
    int trackIndex = 0,
    String storefront = 'de',
  }) async {
    Log.info(
      _tag,
      'play_album',
      data: {
        'albumId': albumId,
        'trackIndex': '$trackIndex',
        'storefront': storefront,
      },
    );
    await _runJs(
      'window.lauschi.play_album('
      '${json.encode(albumId)},$trackIndex,${json.encode(storefront)})',
    );
  }

  Future<void> pause() async {
    Log.debug(_tag, 'JS: pause');
    await _runJs('window.lauschi.pause()');
  }

  Future<void> resume() async {
    Log.debug(_tag, 'JS: resume');
    await _runJs('window.lauschi.resume()');
  }

  Future<void> stop() async {
    Log.debug(_tag, 'JS: stop');
    await _runJs('window.lauschi.stop()');
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
      'auth' => PlayerError.appleMusicAuthExpired,
      'playback' => PlayerError.playbackFailed,
      'init' => PlayerError.playbackFailed,
      _ when message.contains('auth') || message.contains('Auth') =>
        PlayerError.appleMusicAuthExpired,
      _ => PlayerError.playbackFailed,
    };
  }

  /// Permanently shut down. Closes [stateStream].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Log.info(_tag, 'Disposing bridge');
    _developerToken = null;
    _musicUserToken = null;
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
