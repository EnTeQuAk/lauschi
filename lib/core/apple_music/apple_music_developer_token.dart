import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/telemetry/telemetry.dart';

const _tag = 'AppleMusicDeveloperToken';

const _storageKey = 'apple_music_developer_token';

/// Where the lauschi server publishes the token, signed by
/// `tool/sign_apple_music_token.py` from a weekly timer.
const _tokenUrl = 'https://auth.lauschi.app/apple_music_token';

/// The server signs a 30-day token every week. Fetching a new one when
/// fewer than 14 days are left keeps the app working through a missed run
/// or two, and a stored token carries it through a few days offline.
const refreshWhenLeft = Duration(days: 14);

/// The developer token the Android app sends with every Apple Music request.
///
/// The app doesn't hold the MusicKit private key. The server signs a
/// short-lived token and publishes it, and this class fetches it, keeps it
/// in secure storage and fetches a new one before it runs out. iOS doesn't
/// need it, MusicKit makes the token there from the app's MusicKit service.
class AppleMusicDeveloperToken {
  /// [adapter] replaces the HTTP transport and [now] the clock in tests.
  AppleMusicDeveloperToken({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    @visibleForTesting HttpClientAdapter? adapter,
    @visibleForTesting DateTime Function()? now,
  }) : _storage = storage,
       _now = now ?? DateTime.now,
       _dio = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 15),
           receiveTimeout: const Duration(seconds: 15),
           responseType: ResponseType.plain,
         ),
       ) {
    telemetry.instrument(_dio);
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  final Dio _dio;

  /// A token with more than [refreshWhenLeft] to go, fetched when the
  /// stored one is older than that. When the fetch fails, a stored token
  /// that hasn't expired yet still does. Throws when there is none.
  Future<String> current() async {
    final stored = await _storage.read(key: _storageKey);
    final storedExpiry = stored == null ? null : expiryOf(stored);
    if (stored != null &&
        storedExpiry != null &&
        storedExpiry.difference(_now()) > refreshWhenLeft) {
      return stored;
    }
    try {
      final fetched = await _fetch();
      await _storage.write(key: _storageKey, value: fetched);
      Log.info(_tag, 'Fetched a new developer token');
      return fetched;
    } on Exception catch (e) {
      if (stored == null ||
          storedExpiry == null ||
          !storedExpiry.isAfter(_now())) {
        rethrow;
      }
      Log.warn(
        _tag,
        'Fetch failed, keeping the stored token',
        data: {'error': '$e', 'expires': storedExpiry.toIso8601String()},
      );
      return stored;
    }
  }

  Future<String> _fetch() async {
    final response = await _dio.get<String>(_tokenUrl);
    final token = response.data?.trim() ?? '';
    final expiry = expiryOf(token);
    if (expiry == null || !expiry.isAfter(_now())) {
      throw const FormatException('The server sent no valid developer token');
    }
    return token;
  }
}

/// The `exp` claim of a JWT, or null when [token] isn't one.
@visibleForTesting
DateTime? expiryOf(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final exp = payload is Map<String, dynamic> ? payload['exp'] : null;
    return exp is int
        ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
        : null;
  } on FormatException {
    return null;
  }
}
