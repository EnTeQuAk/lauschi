import 'dart:async' show unawaited;

import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_auth.dart';

import 'package:lauschi/features/player/spotify_player_bridge.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'spotify_session.g.dart';

const _tag = 'SpotifySession';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

/// Spotify session state. Drives UI (what to show) and bridge lifecycle
/// (when to init/tearDown).
sealed class SpotifySessionState {
  const SpotifySessionState();
}

/// No valid credentials. Login required.
class SpotifyUnauthenticated extends SpotifySessionState {
  const SpotifyUnauthenticated();
}

/// Checking stored tokens or refreshing.
class SpotifyLoading extends SpotifySessionState {
  const SpotifyLoading();
}

/// Authenticated. Bridge may or may not be ready yet.
class SpotifyAuthenticated extends SpotifySessionState {
  const SpotifyAuthenticated(this.tokens);
  final SpotifyTokens tokens;
}

/// Auth or session error with a user-facing message.
class SpotifyError extends SpotifySessionState {
  const SpotifyError(this.message);
  final String message;
}

// ---------------------------------------------------------------------------
// SpotifySession provider
// ---------------------------------------------------------------------------

/// Central provider for everything Spotify.
///
/// Owns auth state, the API client, and bridge lifecycle. All Spotify
/// consumers (PlayerNotifier, parent screens, onboarding) go through
/// this provider instead of wiring auth, API, and bridge separately.
///
/// Token management: [validToken] is the single entry point. Returns
/// null when unauthenticated (never throws). Used by both the API
/// client's 401-retry and the bridge's SDK token callback.
///
/// Bridge lifecycle: driven by auth state. When authenticated, the
/// bridge is initialized with [validToken] as its token source. When
/// auth is lost (logout, refresh failure), the bridge is torn down.
/// No widget mount/unmount involved.
@Riverpod(keepAlive: true)
class SpotifySession extends _$SpotifySession {
  late final SpotifyAuth _auth;
  late final SpotifyApi _api;
  late final SpotifyPlayerBridge _bridge;

  /// Whether the bridge has been initialized in this auth session.
  /// Reset on logout/tearDown, set after bridge.init() completes.
  bool _bridgeInitialized = false;

  @override
  SpotifySessionState build() {
    _auth = SpotifyAuth();
    _api = SpotifyApi();
    _bridge = SpotifyPlayerBridge();

    // Wire API token refresh: 401 → validToken() → refresh → retry.
    _api.onTokenExpired = validToken;

    ref.onDispose(() {
      unawaited(_bridge.dispose());
    });

    if (!FeatureFlags.enableSpotify) {
      return const SpotifyUnauthenticated();
    }

    // Load stored tokens on startup.
    unawaited(_loadStoredTokens());
    return const SpotifyLoading();
  }

  // ---------------------------------------------------------------------------
  // Public accessors
  // ---------------------------------------------------------------------------

  /// The Spotify Web API client. Always has the current token.
  SpotifyApi get api => _api;

  /// The Spotify Web Playback SDK bridge. Lifecycle managed by session.
  SpotifyPlayerBridge get bridge => _bridge;

  /// Whether the user is currently authenticated with Spotify.
  bool get isAuthenticated => state is SpotifyAuthenticated;

  // ---------------------------------------------------------------------------
  // Token management — single entry point
  // ---------------------------------------------------------------------------

  /// Get a valid (non-expired) access token. Refreshes if needed.
  ///
  /// Returns null when not authenticated. Never throws.
  /// This is the single token entry point for both the API client
  /// (401 retry) and the bridge (SDK token callback).
  ///
  /// Serialized: concurrent callers share a single refresh request.
  Future<String?>? _refreshFuture;

  Future<String?> validToken() async {
    // If a refresh is already in flight, wait for it.
    if (_refreshFuture != null) return _refreshFuture;

    final current = state;
    if (current is! SpotifyAuthenticated) return null;

    // Fast path: token still valid.
    if (!current.tokens.isExpired) return current.tokens.accessToken;

    // Slow path: needs refresh. Serialize concurrent callers.
    _refreshFuture = _doRefresh(current.tokens);
    try {
      return await _refreshFuture;
    } finally {
      _refreshFuture = null;
    }
  }

  Future<String?> _doRefresh(SpotifyTokens tokens) async {
    if (tokens.refreshToken == null) {
      Log.warn(_tag, 'Token expired, no refresh token');
      _onAuthLost();
      return null;
    }

    try {
      final refreshed = await _auth.refresh(tokens.refreshToken!);
      _setAuthenticated(refreshed);
      return refreshed.accessToken;
    } on Exception catch (e) {
      Log.error(_tag, 'Token refresh failed', exception: e);
      _onAuthLost();
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Auth flow
  // ---------------------------------------------------------------------------

  /// Start the PKCE login flow. Opens the system browser.
  Future<void> login() async {
    state = const SpotifyLoading();
    try {
      final tokens = await _auth.login();
      _setAuthenticated(tokens);
      Log.info(_tag, 'Login successful');
    } on Exception catch (e) {
      Log.error(_tag, 'Login failed', exception: e);
      state = SpotifyError('$e');
    }
  }

  /// Handle the OAuth callback deep link.
  /// Returns true if tokens were successfully obtained.
  Future<bool> handleCallback(Uri uri) async {
    try {
      final tokens = await _auth.handleCallback(uri);
      if (tokens != null) {
        _setAuthenticated(tokens);
        Log.info(_tag, 'Authenticated via callback');
        return true;
      }
      return false;
    } on Exception catch (e, stack) {
      Log.error(
        _tag,
        'OAuth callback failed',
        exception: e,
        stackTrace: stack,
      );
      state = SpotifyError('$e');
      return false;
    }
  }

  /// Clear tokens, tear down bridge, return to unauthenticated.
  /// Single logout path for all scenarios (dashboard disconnect,
  /// settings full logout, unrecoverable token failure).
  Future<void> logout() async {
    Log.info(_tag, 'Logging out');
    _tearDownBridge();
    await _auth.logout();
    state = const SpotifyUnauthenticated();
  }

  // ---------------------------------------------------------------------------
  // Bridge lifecycle — driven by auth state
  // ---------------------------------------------------------------------------

  /// Initialize the bridge with the current token source.
  /// Called after authentication is established. The bridge will
  /// use [validToken] for both initial SDK init and token refreshes.
  ///
  /// Must be called from a context where the WebView widget is
  /// mounted (bridge needs a live WebView to load player.html).
  Future<void> initBridge() async {
    if (!isAuthenticated) {
      Log.warn(_tag, 'Cannot init bridge: not authenticated');
      return;
    }
    if (_bridgeInitialized) {
      Log.debug(_tag, 'Bridge already initialized');
      return;
    }

    await _bridge.init(getValidToken: validToken);
    _bridgeInitialized = true;
    Log.info(_tag, 'Bridge initialized');
  }

  /// Tear down the bridge (disconnect SDK, clear controller).
  /// The bridge can be re-initialized via [initBridge] after re-login.
  void _tearDownBridge() {
    if (!_bridgeInitialized) return;
    _bridge.tearDown();
    _bridgeInitialized = false;
    Log.info(_tag, 'Bridge torn down');
  }

  // ---------------------------------------------------------------------------
  // Internal state management
  // ---------------------------------------------------------------------------

  Future<void> _loadStoredTokens() async {
    try {
      final tokens = await _auth.loadStored();
      if (tokens == null) {
        Log.info(_tag, 'No stored tokens');
        state = const SpotifyUnauthenticated();
        return;
      }

      if (tokens.isExpired && tokens.refreshToken != null) {
        Log.info(_tag, 'Stored token expired, refreshing');
        final refreshed = await _auth.refresh(tokens.refreshToken!);
        _setAuthenticated(refreshed);
      } else if (tokens.isExpired) {
        Log.warn(_tag, 'Stored token expired, no refresh token');
        state = const SpotifyUnauthenticated();
      } else {
        _setAuthenticated(tokens);
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Failed to load stored tokens', exception: e);
      state = const SpotifyUnauthenticated();
    }
  }

  /// Transition to authenticated state. Updates both session state
  /// and the API client's token.
  void _setAuthenticated(SpotifyTokens tokens) {
    state = SpotifyAuthenticated(tokens);
    _api.updateToken(tokens.accessToken);
  }

  /// Handle unrecoverable auth loss (refresh failed, token revoked).
  void _onAuthLost() {
    _tearDownBridge();
    state = const SpotifyUnauthenticated();
  }
}
