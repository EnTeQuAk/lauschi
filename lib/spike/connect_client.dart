import 'dart:convert';

import 'package:dio/dio.dart';

import 'spike_logger.dart';
import 'spotify_auth.dart';

/// Spotify Connect approach: no WebView, no DRM, no EME.
/// The Spotify app on the device IS the audio engine.
/// We control it via the Web API.
///
/// Required scopes (already granted):
///   user-read-playback-state, user-modify-playback-state
/// NOT required: streaming (that's only for Web Playback SDK)
class SpotifyConnectClient {
  final _dio = Dio();
  SpotifyTokens? tokens;

  static const _base = 'https://api.spotify.com/v1';

  Options get _auth {
    final token = tokens?.accessToken ?? '';
    return Options(headers: {'Authorization': 'Bearer $token'});
  }

  /// Returns available Spotify Connect devices.
  Future<List<ConnectDevice>> getDevices() async {
    L.info('connect', 'GET /v1/me/player/devices');
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$_base/me/player/devices',
        options: _auth,
      );
      final devices = (resp.data!['devices'] as List<dynamic>)
          .map((d) => ConnectDevice.fromJson(d as Map<String, dynamic>))
          .toList();
      L.info('connect', 'Devices found', data: {
        'count': devices.length.toString(),
        'names': devices.map((d) => '${d.name}(${d.type})').join(', '),
      });
      return devices;
    } on DioException catch (e) {
      L.error('connect', 'getDevices failed', data: {
        'status': e.response?.statusCode?.toString() ?? '?',
        'body': e.response?.data?.toString() ?? e.message ?? '',
      });
      return [];
    }
  }

  /// Transfer playback to a device (does not start playback).
  Future<bool> transferPlayback(String deviceId, {bool play = false}) async {
    L.info('connect', 'Transfer playback', data: {'device_id': deviceId, 'play': play.toString()});
    try {
      final resp = await _dio.put(
        '$_base/me/player',
        data: json.encode({'device_ids': [deviceId], 'play': play}),
        options: _auth,
      );
      L.debug('connect', 'Transfer response', data: {'status': resp.statusCode.toString()});
      return resp.statusCode == 204;
    } on DioException catch (e) {
      L.error('connect', 'Transfer failed', data: {
        'status': e.response?.statusCode?.toString() ?? '?',
        'body': e.response?.data?.toString() ?? e.message ?? '',
      });
      return false;
    }
  }

  /// Start playing a context URI (album, playlist, artist) on a device.
  Future<bool> play(String contextUri, {String? deviceId, int offsetMs = 0}) async {
    final query = deviceId != null ? '?device_id=$deviceId' : '';
    L.info('connect', 'PUT /v1/me/player/play$query', data: {'uri': contextUri});
    try {
      final resp = await _dio.put(
        '$_base/me/player/play$query',
        data: json.encode({
          'context_uri': contextUri,
          if (offsetMs > 0) 'position_ms': offsetMs,
        }),
        options: _auth,
      );
      L.debug('connect', 'Play response', data: {'status': resp.statusCode.toString()});
      return resp.statusCode == 204;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data?.toString() ?? e.message ?? '';
      L.error('connect', 'Play failed', data: {
        'status': status?.toString() ?? '?',
        'body': body,
        'hint': status == 403
            ? 'Premium required or wrong device'
            : status == 404
                ? 'No active device — open Spotify app first'
                : '',
      });
      return false;
    }
  }

  /// Get current playback state. Returns null if nothing is playing.
  Future<ConnectPlaybackState?> getPlaybackState() async {
    L.debug('connect', 'GET /v1/me/player');
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '$_base/me/player',
        options: _auth,
      );
      if (resp.statusCode == 204 || resp.data == null) {
        L.debug('connect', 'No active playback');
        return null;
      }
      final state = ConnectPlaybackState.fromJson(resp.data!);
      L.debug('connect', 'Playback state', data: {
        'playing': (!state.paused).toString(),
        'device': state.deviceName,
        'track': state.trackName ?? 'none',
        'pos_s': (state.progressMs ~/ 1000).toString(),
      });
      return state;
    } on DioException catch (e) {
      L.error('connect', 'getPlaybackState failed', data: {
        'status': e.response?.statusCode?.toString() ?? '?',
      });
      return null;
    }
  }

  Future<bool> pause() async {
    L.info('connect', 'PUT /v1/me/player/pause');
    try {
      await _dio.put('$_base/me/player/pause', options: _auth);
      return true;
    } on DioException catch (e) {
      L.error('connect', 'Pause failed', data: {'status': e.response?.statusCode?.toString() ?? '?'});
      return false;
    }
  }

  Future<bool> resume() async {
    L.info('connect', 'PUT /v1/me/player/play (resume)');
    try {
      await _dio.put('$_base/me/player/play', options: _auth);
      return true;
    } on DioException catch (e) {
      L.error('connect', 'Resume failed', data: {'status': e.response?.statusCode?.toString() ?? '?'});
      return false;
    }
  }

  Future<bool> nextTrack() async {
    L.info('connect', 'POST /v1/me/player/next');
    try {
      await _dio.post('$_base/me/player/next', options: _auth);
      return true;
    } on DioException catch (e) {
      L.error('connect', 'Next failed', data: {'status': e.response?.statusCode?.toString() ?? '?'});
      return false;
    }
  }
}

class ConnectDevice {
  final String id;
  final String name;
  final String type;
  final bool isActive;
  final int volumePercent;

  const ConnectDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.isActive,
    required this.volumePercent,
  });

  factory ConnectDevice.fromJson(Map<String, dynamic> j) => ConnectDevice(
        id: j['id'] as String,
        name: j['name'] as String,
        type: j['type'] as String,
        isActive: j['is_active'] as bool,
        volumePercent: j['volume_percent'] as int? ?? 0,
      );

  @override
  String toString() => '$name ($type)${isActive ? ' [active]' : ''}';
}

class ConnectPlaybackState {
  final bool paused;
  final int progressMs;
  final String deviceName;
  final String? trackName;
  final String? artistName;
  final String? albumName;
  final String? artworkUrl;

  const ConnectPlaybackState({
    required this.paused,
    required this.progressMs,
    required this.deviceName,
    this.trackName,
    this.artistName,
    this.albumName,
    this.artworkUrl,
  });

  factory ConnectPlaybackState.fromJson(Map<String, dynamic> j) {
    final item = j['item'] as Map<String, dynamic>?;
    final artists = item?['artists'] as List<dynamic>?;
    final album = item?['album'] as Map<String, dynamic>?;
    final images = album?['images'] as List<dynamic>?;
    return ConnectPlaybackState(
      paused: !(j['is_playing'] as bool? ?? false),
      progressMs: j['progress_ms'] as int? ?? 0,
      deviceName: (j['device'] as Map<String, dynamic>?)?['name'] as String? ?? '?',
      trackName: item?['name'] as String?,
      artistName: artists?.isNotEmpty == true
          ? (artists!.first as Map<String, dynamic>)['name'] as String?
          : null,
      albumName: album?['name'] as String?,
      artworkUrl: images?.isNotEmpty == true
          ? (images!.first as Map<String, dynamic>)['url'] as String?
          : null,
    );
  }
}
