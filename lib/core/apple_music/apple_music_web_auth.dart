import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/log.dart';
import 'package:url_launcher/url_launcher.dart';

const _tag = 'AppleMusicWebAuth';

const _tokenKey = 'apple_music_user_token';
const _storefrontKey = 'apple_music_storefront';
const _pendingStateKey = 'apple_music_pending_state';

/// Auth page hosted alongside the player HTML. Opens in the system browser,
/// runs MusicKit JS authorize(), redirects back with the token.
const _authPageUrl =
    'https://tuneloopbot.webshox.org/lauschi/apple_music_auth.html';

const _defaultStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

/// Token set from Apple Music web auth.
@immutable
class AppleMusicTokens {
  const AppleMusicTokens({
    required this.musicUserToken,
    required this.storefront,
  });

  /// The Music User Token from MusicKit JS authorize().
  /// Valid for ~180 days. No refresh token available.
  final String musicUserToken;

  /// The user's storefront (e.g. 'de', 'at', 'us').
  final String storefront;
}

/// Handles Apple Music web auth flow via system browser.
///
/// Mirrors `SpotifyAuth` exactly:
/// 1. [login] opens system browser with auth page
/// 2. Auth page loads MusicKit JS, calls authorize()
/// 3. After login, auth page redirects to lauschi://apple-music-callback?code=TOKEN
/// 4. [handleCallback] extracts the token and stores it
class AppleMusicWebAuth {
  AppleMusicWebAuth({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? _defaultStorage;

  final FlutterSecureStorage _storage;

  Completer<AppleMusicTokens>? _loginCompleter;
  String? _pendingState;

  /// Open the system browser for Apple Music login.
  ///
  /// Returns when [handleCallback] is called with the redirect URI.
  Future<AppleMusicTokens> login({required String developerToken}) async {
    // Prevent concurrent login attempts.
    if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
      Log.warn(_tag, 'Login already in progress');
      return _loginCompleter!.future;
    }

    final state = _randomHex(16);
    _pendingState = state;
    _loginCompleter = Completer<AppleMusicTokens>();

    // Persist state for app-kill recovery.
    await _storage.write(key: _pendingStateKey, value: state);

    final authUrl = Uri.parse(_authPageUrl).replace(
      queryParameters: {
        'token': developerToken,
        'state': state,
      },
    );

    Log.info(_tag, 'Opening browser for Apple Music auth');

    // Use externalApplication (full browser), NOT inAppBrowserView
    // (Custom Tab). MusicKit JS authorize() opens a popup for Apple
    // login. Custom Tabs don't support popups; they fall back to
    // redirect-based auth which loses MusicKit JS session state.
    // Full browser keeps popups working, same as how music.apple.com works.
    var launched = false;
    for (final mode in [
      LaunchMode.externalApplication,
      LaunchMode.platformDefault,
    ]) {
      try {
        launched = await launchUrl(authUrl, mode: mode);
        Log.info(_tag, '${mode.name}: $launched');
        if (launched) break;
      } on Exception catch (e) {
        Log.warn(_tag, '${mode.name} threw: $e');
      }
    }

    if (!launched) {
      _loginCompleter = null;
      throw StateError('Could not open browser for Apple Music login');
    }

    return _loginCompleter!.future;
  }

  /// Handle the deep link callback from the auth page.
  ///
  /// Called by the app's deep link handler when
  /// `lauschi://apple-music-callback` is received.
  Future<AppleMusicTokens?> handleCallback(Uri uri) async {
    var expectedState = _pendingState;

    // Recover from app-kill during auth.
    if (expectedState == null) {
      expectedState = await _storage.read(key: _pendingStateKey);
      if (expectedState != null) {
        Log.info(_tag, 'Recovered pending auth from storage');
      }
    }

    if (expectedState == null) {
      Log.warn(_tag, 'Callback received but no login pending');
      return null;
    }

    try {
      // Verify state (CSRF protection).
      if (uri.queryParameters['state'] != expectedState) {
        throw StateError('OAuth state mismatch');
      }

      // Check for error.
      final error = uri.queryParameters['error'];
      if (error != null) {
        throw StateError('Auth error: $error');
      }

      // Extract token.
      final token = uri.queryParameters['code'];
      if (token == null || token.isEmpty) {
        throw StateError('No token in callback');
      }

      final storefront = uri.queryParameters['storefront'] ?? 'de';

      Log.info(
        _tag,
        'Token received',
        data: {
          'length': '${token.length}',
          'storefront': storefront,
        },
      );

      final tokens = AppleMusicTokens(
        musicUserToken: token,
        storefront: storefront,
      );

      // Persist.
      await Future.wait([
        _storage.write(key: _tokenKey, value: token),
        _storage.write(key: _storefrontKey, value: storefront),
      ]);

      _loginCompleter?.complete(tokens);
      return tokens;
    } on Exception catch (e) {
      Log.error(_tag, 'Callback handling failed', exception: e);
      _loginCompleter?.completeError(e);
      return null;
    } finally {
      _loginCompleter = null;
      _pendingState = null;
      // No closeInAppWebView() needed since we use externalApplication
      // (full browser). The browser tab stays open but the user is back
      // in the app via the deep link.
      await _storage.delete(key: _pendingStateKey);
    }
  }

  /// Load previously stored tokens.
  Future<AppleMusicTokens?> loadStored() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) {
      Log.debug(_tag, 'No stored Apple Music token');
      return null;
    }

    final storefront = await _storage.read(key: _storefrontKey) ?? 'de';
    Log.info(
      _tag,
      'Loaded stored token',
      data: {'length': '${token.length}', 'storefront': storefront},
    );

    return AppleMusicTokens(
      musicUserToken: token,
      storefront: storefront,
    );
  }

  /// Clear stored tokens.
  Future<void> logout() async {
    Log.info(_tag, 'Clearing stored Apple Music tokens');
    await Future.wait([
      _storage.delete(key: _tokenKey),
      _storage.delete(key: _storefrontKey),
    ]);
  }

  static String _randomHex(int byteLength) {
    final rand = Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
