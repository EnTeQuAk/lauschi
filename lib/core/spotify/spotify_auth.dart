import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_config.dart';

const _tag = 'SpotifyAuth';

const _tokenKey = 'spotify_access_token';
const _refreshKey = 'spotify_refresh_token';
const _expiryKey = 'spotify_token_expiry';

/// Token set returned from Spotify OAuth.
class SpotifyTokens {
  const SpotifyTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiry,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiry;

  /// Token is considered expired 2 minutes before actual expiry
  /// to avoid races during API calls.
  bool get isExpired =>
      DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 2)));
}

/// Handles Spotify PKCE OAuth flow, token storage, and refresh.
class SpotifyAuth {
  SpotifyAuth({
    FlutterSecureStorage? storage,
    Dio? dio,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _dio = dio ?? Dio();

  final FlutterSecureStorage _storage;
  final Dio _dio;

  /// Run the full PKCE authorization code flow.
  ///
  /// Opens a browser for Spotify login, exchanges the code for tokens,
  /// and persists them in secure storage.
  Future<SpotifyTokens> login() async {
    assert(
      SpotifyConfig.clientId.isNotEmpty,
      'SPOTIFY_CLIENT_ID must be set via --dart-define',
    );

    final pkce = _generatePkce();
    final state = _randomBase64(16);

    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': SpotifyConfig.clientId,
      'response_type': 'code',
      'redirect_uri': SpotifyConfig.redirectUri,
      'scope': SpotifyConfig.scopes.join(' '),
      'code_challenge_method': 'S256',
      'code_challenge': pkce.challenge,
      'state': state,
    });

    Log.info(_tag, 'Starting PKCE OAuth flow');

    // TODO: implement browser-based auth flow (url_launcher + intent filter)
    // The flow is: open authUrl in browser → user logs in → Spotify redirects
    // to lauschi://callback?code=...&state=... → app handles deep link →
    // call _exchangeCode(code, pkce.verifier).
    throw UnimplementedError(
      'Browser auth not implemented. Auth URL: $authUrl',
    );
  }

  /// Refresh an expired token using the refresh token.
  Future<SpotifyTokens> refresh(String refreshToken) async {
    Log.info(_tag, 'Refreshing access token');
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        'https://accounts.spotify.com/api/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': SpotifyConfig.clientId,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return _saveAndReturn(resp.data!, fallbackRefreshToken: refreshToken);
    } on DioException catch (e) {
      Log.error(_tag, 'Token refresh failed', data: {
        'status': '${e.response?.statusCode}',
      });
      rethrow;
    }
  }

  /// Load previously stored tokens from secure storage.
  Future<SpotifyTokens?> loadStored() async {
    final token = await _storage.read(key: _tokenKey);
    final refreshToken = await _storage.read(key: _refreshKey);
    final expiryStr = await _storage.read(key: _expiryKey);

    if (token == null || expiryStr == null) {
      Log.debug(_tag, 'No stored tokens');
      return null;
    }

    final expiry = DateTime.parse(expiryStr);
    Log.info(_tag, 'Loaded stored tokens', data: {
      'expired': '${DateTime.now().isAfter(expiry)}',
    });

    return SpotifyTokens(
      accessToken: token,
      refreshToken: refreshToken,
      expiry: expiry,
    );
  }

  /// Get a valid (non-expired) access token, refreshing if needed.
  Future<String> validAccessToken(SpotifyTokens tokens) async {
    if (!tokens.isExpired) return tokens.accessToken;

    if (tokens.refreshToken == null) {
      throw StateError('Token expired and no refresh token available');
    }

    Log.info(_tag, 'Token expired, refreshing');
    final refreshed = await refresh(tokens.refreshToken!);
    return refreshed.accessToken;
  }

  /// Clear all stored tokens.
  Future<void> logout() async {
    Log.info(_tag, 'Clearing stored tokens');
    await Future.wait([
      _storage.delete(key: _tokenKey),
      _storage.delete(key: _refreshKey),
      _storage.delete(key: _expiryKey),
    ]);
  }

  // -- Private --

  // ignore: unused_element, called once browser auth flow is wired
  Future<SpotifyTokens> _exchangeCode(String code, String verifier) async {
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        'https://accounts.spotify.com/api/token',
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': SpotifyConfig.redirectUri,
          'client_id': SpotifyConfig.clientId,
          'code_verifier': verifier,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      Log.info(_tag, 'Token exchange success');
      return _saveAndReturn(resp.data!);
    } on DioException catch (e) {
      Log.error(_tag, 'Token exchange failed', data: {
        'status': '${e.response?.statusCode}',
      });
      rethrow;
    }
  }

  Future<SpotifyTokens> _saveAndReturn(
    Map<String, dynamic> data, {
    String? fallbackRefreshToken,
  }) async {
    final accessToken = data['access_token'] as String;
    final refreshToken =
        (data['refresh_token'] as String?) ?? fallbackRefreshToken;
    final expiresIn = data['expires_in'] as int? ?? 3600;
    final expiry = DateTime.now().add(Duration(seconds: expiresIn));

    await Future.wait([
      _storage.write(key: _tokenKey, value: accessToken),
      if (refreshToken != null)
        _storage.write(key: _refreshKey, value: refreshToken),
      _storage.write(key: _expiryKey, value: expiry.toIso8601String()),
    ]);

    return SpotifyTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiry: expiry,
    );
  }

  static ({String verifier, String challenge}) _generatePkce() {
    final verifier = _randomBase64(32);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    return (verifier: verifier, challenge: challenge);
  }

  static String _randomBase64(int byteLength) {
    final rand = Random.secure();
    return base64UrlEncode(
      List<int>.generate(byteLength, (_) => rand.nextInt(256)),
    ).replaceAll('=', '');
  }
}
