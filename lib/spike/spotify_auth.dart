import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'spike_secrets.dart';

const _scopes = [
  'streaming',
  'user-read-playback-state',
  'user-modify-playback-state',
  'user-read-currently-playing',
  'user-read-private', // needed to verify Premium status
];

const _tokenKey = 'spike_access_token';
const _refreshKey = 'spike_refresh_token';
const _expiryKey = 'spike_token_expiry';

class SpotifyTokens {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiry;

  const SpotifyTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiry,
  });

  bool get isExpired => DateTime.now().isAfter(expiry.subtract(const Duration(minutes: 2)));
}

class SpotifyAuth {
  static const _storage = FlutterSecureStorage();
  static final _dio = Dio();

  // Generate PKCE code verifier + challenge.
  static ({String verifier, String challenge}) _pkce() {
    final rand = Random.secure();
    final verifier = base64UrlEncode(
      List<int>.generate(32, (_) => rand.nextInt(256)),
    ).replaceAll('=', '');
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    return (verifier: verifier, challenge: challenge);
  }

  static Future<SpotifyTokens> login() async {
    final pkce = _pkce();
    final state = base64UrlEncode(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');

    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': SpikeSecrets.spotifyClientId,
      'response_type': 'code',
      'redirect_uri': SpikeSecrets.spotifyRedirectUri,
      'scope': _scopes.join(' '),
      'code_challenge_method': 'S256',
      'code_challenge': pkce.challenge,
      'state': state,
    });

    final result = await FlutterWebAuth2.authenticate(
      url: authUrl.toString(),
      callbackUrlScheme: 'lauschi',
    );

    final resultUri = Uri.parse(result);
    if (resultUri.queryParameters['state'] != state) {
      throw StateError('OAuth state mismatch — possible CSRF');
    }

    final code = resultUri.queryParameters['code'];
    if (code == null) {
      throw StateError('No code in OAuth callback: $result');
    }

    return _exchangeCode(code, pkce.verifier);
  }

  static Future<SpotifyTokens> _exchangeCode(String code, String verifier) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      'https://accounts.spotify.com/api/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': SpikeSecrets.spotifyRedirectUri,
        'client_id': SpikeSecrets.spotifyClientId,
        'code_verifier': verifier,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );

    return _saveAndReturn(resp.data!);
  }

  static Future<SpotifyTokens> refresh(String refreshToken) async {
    final resp = await _dio.post<Map<String, dynamic>>(
      'https://accounts.spotify.com/api/token',
      data: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': SpikeSecrets.spotifyClientId,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
      ),
    );

    return _saveAndReturn(resp.data!, existingRefreshToken: refreshToken);
  }

  static Future<SpotifyTokens> _saveAndReturn(
    Map<String, dynamic> data, {
    String? existingRefreshToken,
  }) async {
    final accessToken = data['access_token'] as String;
    final refreshToken = (data['refresh_token'] as String?) ?? existingRefreshToken;
    final expiresIn = data['expires_in'] as int? ?? 3600;
    final expiry = DateTime.now().add(Duration(seconds: expiresIn));

    await Future.wait([
      _storage.write(key: _tokenKey, value: accessToken),
      if (refreshToken != null) _storage.write(key: _refreshKey, value: refreshToken),
      _storage.write(key: _expiryKey, value: expiry.toIso8601String()),
    ]);

    return SpotifyTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiry: expiry,
    );
  }

  static Future<SpotifyTokens?> loadStored() async {
    final token = await _storage.read(key: _tokenKey);
    final refresh = await _storage.read(key: _refreshKey);
    final expiryStr = await _storage.read(key: _expiryKey);
    if (token == null || expiryStr == null) return null;

    return SpotifyTokens(
      accessToken: token,
      refreshToken: refresh,
      expiry: DateTime.parse(expiryStr),
    );
  }

  static Future<void> logout() async {
    await Future.wait([
      _storage.delete(key: _tokenKey),
      _storage.delete(key: _refreshKey),
      _storage.delete(key: _expiryKey),
    ]);
  }

  // Returns a valid (non-expired) access token, refreshing if needed.
  static Future<String> validToken(SpotifyTokens tokens) async {
    if (!tokens.isExpired) return tokens.accessToken;
    if (tokens.refreshToken == null) throw StateError('No refresh token');
    final refreshed = await refresh(tokens.refreshToken!);
    return refreshed.accessToken;
  }
}
