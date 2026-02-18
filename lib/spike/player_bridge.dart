import 'dart:async' show StreamController, unawaited;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'spike_logger.dart';
import 'spotify_auth.dart';

/// Events arriving from the Spotify Web Playback SDK via the JS bridge.
sealed class PlayerEvent {}

class PlayerReady extends PlayerEvent {
  final String deviceId;
  PlayerReady(this.deviceId);
}

class PlayerNotReady extends PlayerEvent {}

class PlayerStateChanged extends PlayerEvent {
  final bool paused;
  final int positionMs;
  final int durationMs;
  final TrackInfo? track;

  PlayerStateChanged({
    required this.paused,
    required this.positionMs,
    required this.durationMs,
    this.track,
  });
}

class PlayerError extends PlayerEvent {
  final String type;
  final String message;
  PlayerError(this.type, this.message);
}

class TrackInfo {
  final String uri;
  final String name;
  final String artist;
  final String album;
  final String? artworkUrl;

  const TrackInfo({
    required this.uri,
    required this.name,
    required this.artist,
    required this.album,
    this.artworkUrl,
  });
}

/// Manages the hidden WebView that hosts the Spotify Web Playback SDK.
class SpotifyPlayerBridge {
  final _events = StreamController<PlayerEvent>.broadcast();
  final _dio = Dio();

  Stream<PlayerEvent> get events => _events.stream;

  late final WebViewController controller;
  SpotifyTokens? _tokens;
  String? _deviceId;

  bool get hasDevice => _deviceId != null;

  Future<void> init(SpotifyTokens tokens) async {
    _tokens = tokens;
    L.info('bridge', 'Initialising WebViewController');

    controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);

    // WORKAROUND: Spotify Web Playback SDK checks the browser UA before initialising
    // EME/Widevine. Android WebView uses a non-Chrome UA string by default, causing
    // `No supported keysystem was found` even when Widevine L3 is available on device.
    // Setting a standard mobile Chrome UA passes the SDK's capability gate.
    // TODO: file upstream — Spotify should detect Widevine capability directly, not via UA.
    const ua = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/144.0.7559.132 Mobile Safari/537.36';
    await controller.setUserAgent(ua);
    L.debug('bridge', 'User-Agent set', data: {'ua': ua});

    await controller.addJavaScriptChannel(
      'SpotifyBridge',
      onMessageReceived: _onMessage,
    );
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageStarted: (url) => L.debug('bridge', 'Page started', data: {'url': url}),
      onPageFinished: (url) {
        L.info('bridge', 'Page loaded', data: {'url': url});
        _onPageLoaded();
      },
      onWebResourceError: (err) {
        L.error('bridge', 'WebResource error', data: {
          'code': err.errorCode.toString(),
          'type': err.errorType?.toString() ?? '?',
          'desc': err.description,
          'url': err.url ?? '',
        });
        _events.add(PlayerError('webview', '${err.errorCode}: ${err.description}'));
      },
      onNavigationRequest: (req) {
        L.debug('bridge', 'Navigation request', data: {'url': req.url});
        return NavigationDecision.navigate;
      },
    ));

    // HTTPS origin so Android WebView may expose Widevine via EME —
    // file:// origin was blocking requestMediaKeySystemAccess.
    // Deployed via: mise run deploy-player
    const playerUrl = 'https://tuneloopbot.webshox.org/lauschi/player.html';
    L.info('bridge', 'Loading player.html', data: {'url': playerUrl});
    await controller.loadRequest(Uri.parse(playerUrl));
  }

  void _onPageLoaded() {
    // SDK init triggered by sdk_ready event from JS, not here.
  }

  void _onMessage(JavaScriptMessage msg) {
    late Map<String, dynamic> data;
    try {
      data = json.decode(msg.message) as Map<String, dynamic>;
    } catch (e) {
      L.error('bridge', 'Invalid JSON from JS', data: {'raw': msg.message});
      return;
    }

    final type = data['type'] as String?;
    final payload = data['payload'] as Map<String, dynamic>? ?? {};

    // Log every incoming message. state_changed and log are debug to avoid spam.
    final payloadData = payload.isEmpty ? null : Map<String, dynamic>.from(payload);
    switch (type) {
      case 'state_changed' || 'log':
        L.debug('js→dart', type ?? 'unknown', data: payloadData);
      case 'error':
        L.error('js→dart', type ?? 'unknown', data: payloadData);
      default:
        L.info('js→dart', type ?? 'unknown', data: payloadData);
    }

    switch (type) {
      case 'sdk_ready':
        unawaited(_initPlayer());

      case 'ready':
        _deviceId = payload['device_id'] as String?;
        L.info('bridge', 'Player READY', data: {'device_id': _deviceId ?? '?'});
        _events.add(PlayerReady(_deviceId!));

      case 'not_ready':
        _deviceId = null;
        L.warn('bridge', 'Player NOT READY');
        _events.add(PlayerNotReady());

      case 'state_changed':
        final trackData = payload['track'] as Map<String, dynamic>?;
        final paused = payload['paused'] as bool? ?? true;
        final posMs = payload['position_ms'] as int? ?? 0;
        final durMs = payload['duration_ms'] as int? ?? 0;
        if (trackData != null) {
          L.debug('bridge', 'State changed', data: {
            'paused': paused.toString(),
            'pos': '${posMs ~/ 1000}s',
            'track': trackData['name'] as String? ?? '?',
          });
        }
        _events.add(PlayerStateChanged(
          paused: paused,
          positionMs: posMs,
          durationMs: durMs,
          track: trackData == null
              ? null
              : TrackInfo(
                  uri: trackData['uri'] as String,
                  name: trackData['name'] as String,
                  artist: trackData['artist'] as String,
                  album: trackData['album'] as String,
                  artworkUrl: trackData['artwork_url'] as String?,
                ),
        ));

      case 'token_request':
        L.info('bridge', 'SDK requesting token refresh');
        unawaited(_deliverFreshToken());

      case 'play_request':
        final uri = payload['uri'] as String?;
        final deviceId = payload['device_id'] as String?;
        L.info('bridge', 'Play request', data: {'uri': uri ?? '?', 'device_id': deviceId ?? '?'});
        if (uri != null && deviceId != null) {
          unawaited(_startPlayback(uri, deviceId));
        }

      case 'error':
        final errType = payload['type'] as String? ?? 'unknown';
        final errMsg = payload['message'] as String? ?? '';
        L.error('bridge', 'SDK error', data: {'type': errType, 'message': errMsg});
        _events.add(PlayerError(errType, errMsg));

      case 'log':
        // Already logged above via the generic handler.
        break;

      default:
        L.warn('bridge', 'Unknown event type', data: {'type': type ?? 'null'});
    }
  }

  Future<void> _initPlayer() async {
    if (_tokens == null) return;
    L.info('bridge', 'Calling lauschi.init() with access token');
    final token = await SpotifyAuth.validToken(_tokens!);
    final safeToken = token.replaceAll('"', '\\"');
    await controller.runJavaScript('window.lauschi.init("$safeToken")');
    L.debug('dart→js', 'lauschi.init(token)');
  }

  Future<void> _deliverFreshToken() async {
    if (_tokens == null) return;
    try {
      final token = await SpotifyAuth.validToken(_tokens!);
      final safeToken = token.replaceAll('"', '\\"');
      await controller.runJavaScript('window.lauschi.deliver_token("$safeToken")');
      L.debug('dart→js', 'lauschi.deliver_token(token)');
    } catch (e) {
      L.error('bridge', 'Token delivery failed', data: {'error': e.toString()});
      _events.add(PlayerError('token_refresh', e.toString()));
    }
  }

  /// Transfer playback to our WebView device and start playing a URI.
  Future<void> _startPlayback(String uri, String deviceId) async {
    if (_tokens == null) return;
    try {
      final token = await SpotifyAuth.validToken(_tokens!);

      L.info('api', 'PUT /v1/me/player (transfer)', data: {'device_id': deviceId});
      final transferResp = await _dio.put(
        'https://api.spotify.com/v1/me/player',
        data: json.encode({'device_ids': [deviceId], 'play': false}),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      L.debug('api', 'Transfer response', data: {'status': transferResp.statusCode.toString()});

      L.info('api', 'PUT /v1/me/player/play', data: {'uri': uri, 'device_id': deviceId});
      final playResp = await _dio.put(
        'https://api.spotify.com/v1/me/player/play?device_id=$deviceId',
        data: json.encode({'context_uri': uri}),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      L.debug('api', 'Play response', data: {'status': playResp.statusCode.toString()});
    } on DioException catch (e) {
      L.error('api', 'Playback start failed', data: {
        'status': e.response?.statusCode?.toString() ?? '?',
        'body': e.response?.data?.toString() ?? e.message ?? '',
      });
      _events.add(PlayerError('playback_start', '${e.response?.statusCode}: ${e.message}'));
    }
  }

  // Commands to JS.

  Future<void> play(String spotifyUri) async {
    L.info('dart→js', 'lauschi.play()', data: {'uri': spotifyUri});
    await controller.runJavaScript(
      'window.lauschi.play("${spotifyUri.replaceAll('"', '\\"')}")',
    );
  }

  Future<void> togglePlay() async {
    L.debug('dart→js', 'lauschi.toggle_play()');
    await controller.runJavaScript('window.lauschi.toggle_play()');
  }

  Future<void> nextTrack() async {
    L.debug('dart→js', 'lauschi.next_track()');
    await controller.runJavaScript('window.lauschi.next_track()');
  }

  Future<void> prevTrack() async {
    L.debug('dart→js', 'lauschi.prev_track()');
    await controller.runJavaScript('window.lauschi.prev_track()');
  }

  Future<void> seek(int positionMs) async {
    L.debug('dart→js', 'lauschi.seek()', data: {'position_ms': positionMs.toString()});
    await controller.runJavaScript('window.lauschi.seek($positionMs)');
  }

  void dispose() {
    L.info('bridge', 'Disposing bridge');
    unawaited(controller.runJavaScript('window.lauschi.disconnect()'));
    _events.close();
  }
}
