import 'dart:async' show StreamController, unawaited;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

class PlayerLog extends PlayerEvent {
  final String message;
  PlayerLog(this.message);
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

    controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'SpotifyBridge',
      onMessageReceived: _onMessage,
    );
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) => _onPageLoaded(),
      onWebResourceError: (err) {
        _events.add(PlayerError('webview', '${err.errorCode}: ${err.description}'));
      },
    ));
    await controller.loadFlutterAsset('assets/player.html');
  }

  void _onPageLoaded() {
    _events.add(PlayerLog('player.html loaded'));
    // SDK init happens after sdk_ready event from JS.
  }

  void _onMessage(JavaScriptMessage msg) {
    late Map<String, dynamic> data;
    try {
      data = json.decode(msg.message) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[bridge] invalid JSON: ${msg.message}');
      return;
    }

    final type = data['type'] as String?;
    final payload = data['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'sdk_ready':
        unawaited(_initPlayer());
      case 'ready':
        _deviceId = payload['device_id'] as String?;
        _events.add(PlayerReady(_deviceId!));
      case 'not_ready':
        _deviceId = null;
        _events.add(PlayerNotReady());
      case 'state_changed':
        final trackData = payload['track'] as Map<String, dynamic>?;
        _events.add(PlayerStateChanged(
          paused: payload['paused'] as bool? ?? true,
          positionMs: payload['position_ms'] as int? ?? 0,
          durationMs: payload['duration_ms'] as int? ?? 0,
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
        // JS SDK is requesting a (possibly refreshed) token.
        unawaited(_deliverFreshToken());
      case 'play_request':
        // JS received play(uri) call — now transfer playback via Web API.
        final uri = payload['uri'] as String?;
        final deviceId = payload['device_id'] as String?;
        if (uri != null && deviceId != null) {
          unawaited(_startPlayback(uri, deviceId));
        }
      case 'error':
        _events.add(PlayerError(
          payload['type'] as String? ?? 'unknown',
          payload['message'] as String? ?? '',
        ));
      case 'log':
        final msg = payload['message'] as String? ?? '';
        debugPrint('[spotify-sdk] $msg');
        _events.add(PlayerLog(msg));
      default:
        debugPrint('[bridge] unknown event: $type');
    }
  }

  Future<void> _initPlayer() async {
    if (_tokens == null) return;
    final token = await SpotifyAuth.validToken(_tokens!);
    // Escape backticks/quotes in token (should never happen, but be safe).
    final safeToken = token.replaceAll('"', '\\"');
    await controller.runJavaScript('window.lauschi.init("$safeToken")');
  }

  Future<void> _deliverFreshToken() async {
    if (_tokens == null) return;
    try {
      final token = await SpotifyAuth.validToken(_tokens!);
      final safeToken = token.replaceAll('"', '\\"');
      await controller.runJavaScript('window.lauschi.deliver_token("$safeToken")');
    } catch (e) {
      _events.add(PlayerError('token_refresh', e.toString()));
    }
  }

  /// Transfer playback to our WebView device and start playing a Spotify URI.
  ///
  /// Uses the Spotify Web API (not the SDK) so the JS side stays simple.
  Future<void> _startPlayback(String uri, String deviceId) async {
    if (_tokens == null) return;
    try {
      final token = await SpotifyAuth.validToken(_tokens!);
      // Transfer playback to our device.
      await _dio.put(
        'https://api.spotify.com/v1/me/player',
        data: json.encode({'device_ids': [deviceId], 'play': false}),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      // Start playback of the requested URI.
      await _dio.put(
        'https://api.spotify.com/v1/me/player/play?device_id=$deviceId',
        data: json.encode({'context_uri': uri}),
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
    } on DioException catch (e) {
      _events.add(PlayerError('playback_start', '${e.response?.statusCode}: ${e.message}'));
    }
  }

  // Commands sent to the JS layer.

  Future<void> play(String spotifyUri) async {
    await controller.runJavaScript(
      'window.lauschi.play("${spotifyUri.replaceAll('"', '\\"')}")',
    );
  }

  Future<void> togglePlay() => controller.runJavaScript('window.lauschi.toggle_play()');
  Future<void> nextTrack() => controller.runJavaScript('window.lauschi.next_track()');
  Future<void> prevTrack() => controller.runJavaScript('window.lauschi.prev_track()');

  Future<void> seek(int positionMs) =>
      controller.runJavaScript('window.lauschi.seek($positionMs)');

  void dispose() {
    controller.runJavaScript('window.lauschi.disconnect()');
    _events.close();
  }
}
