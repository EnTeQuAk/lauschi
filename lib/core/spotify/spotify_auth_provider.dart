import 'dart:async' show unawaited;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_auth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'spotify_auth_provider.g.dart';

const _tag = 'AuthProvider';

/// Authentication state for Spotify.
sealed class SpotifyAuthState {
  const SpotifyAuthState();
}

class AuthLoading extends SpotifyAuthState {
  const AuthLoading();
}

class AuthUnauthenticated extends SpotifyAuthState {
  const AuthUnauthenticated();
}

class AuthAuthenticated extends SpotifyAuthState {
  const AuthAuthenticated(this.tokens);
  final SpotifyTokens tokens;
}

class AuthError extends SpotifyAuthState {
  const AuthError(this.message);
  final String message;
}

@Riverpod(keepAlive: true)
SpotifyAuth spotifyAuth(Ref ref) => SpotifyAuth();

/// Manages Spotify authentication state.
///
/// On creation, attempts to load stored tokens. Exposes methods to
/// login, logout, and get a valid access token.
@Riverpod(keepAlive: true)
class SpotifyAuthNotifier extends _$SpotifyAuthNotifier {
  late final SpotifyAuth _auth;

  @override
  SpotifyAuthState build() {
    _auth = ref.watch(spotifyAuthProvider);
    // Kick off async token load. State starts as loading.
    unawaited(_loadStoredTokens());
    return const AuthLoading();
  }

  Future<void> _loadStoredTokens() async {
    try {
      final tokens = await _auth.loadStored();
      if (tokens == null) {
        state = const AuthUnauthenticated();
        return;
      }

      // If expired, try to refresh
      if (tokens.isExpired && tokens.refreshToken != null) {
        Log.info(_tag, 'Stored token expired, refreshing');
        final refreshed = await _auth.refresh(tokens.refreshToken!);
        state = AuthAuthenticated(refreshed);
      } else if (tokens.isExpired) {
        Log.warn(_tag, 'Stored token expired, no refresh token');
        state = const AuthUnauthenticated();
      } else {
        state = AuthAuthenticated(tokens);
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load stored tokens', exception: e);
      state = const AuthUnauthenticated();
    }
  }

  /// Start the PKCE login flow.
  Future<void> login() async {
    state = const AuthLoading();
    try {
      final tokens = await _auth.login();
      state = AuthAuthenticated(tokens);
      Log.info(_tag, 'Login successful');
    } on Exception catch (e) {
      Log.error(_tag, 'Login failed', exception: e);
      state = AuthError('$e');
    }
  }

  /// Clear tokens and return to unauthenticated state.
  Future<void> logout() async {
    await _auth.logout();
    state = const AuthUnauthenticated();
    Log.info(_tag, 'Logged out');
  }

  /// Update tokens from an external source (e.g., bridge token refresh).
  /// Keeps all providers in sync without triggering a full reload.
  void updateTokens(SpotifyTokens tokens) {
    state = AuthAuthenticated(tokens);
    Log.debug(_tag, 'Tokens updated externally');
  }

  /// Get a valid access token, refreshing if needed.
  /// Returns null if not authenticated.
  Future<String?> validAccessToken() async {
    final current = state;
    if (current is! AuthAuthenticated) return null;

    try {
      final token = await _auth.validAccessToken(current.tokens);
      // If tokens were refreshed, the new ones are in secure storage.
      // Reload to update state.
      if (current.tokens.isExpired) {
        final fresh = await _auth.loadStored();
        if (fresh != null) state = AuthAuthenticated(fresh);
      }
      return token;
    } on Exception catch (e) {
      Log.error(_tag, 'Token refresh failed', exception: e);
      state = const AuthUnauthenticated();
      return null;
    }
  }
}
