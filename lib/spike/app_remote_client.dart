import 'dart:async' show StreamController, StreamSubscription, unawaited;

import 'package:spotify_sdk/models/player_state.dart';
import 'package:spotify_sdk/spotify_sdk.dart';

import 'spike_logger.dart';
import 'spike_secrets.dart';

// Redirect URI must match manifestPlaceholders in build.gradle.kts:
//   redirectSchemeName = "spotify-sdk", redirectHostName = "auth"
const _redirectUri = 'spotify-sdk://auth';

/// Wraps the Spotify App Remote SDK (native iOS/Android IPC to the Spotify app).
///
/// Key difference from Connect API:
///   - Connects via local IPC — no HTTP, works offline
///   - Launches Spotify automatically if not running
///   - Spotify plays in background, lauschi stays in foreground
///   - No EME/DRM issue — Spotify's native player handles everything
///
/// Requires:
///   - Spotify app installed
///   - Package name + SHA-1 registered in Spotify Developer Dashboard
///   - Redirect URIs in Spotify Dashboard: lauschi://callback AND spotify-sdk://auth
class AppRemoteClient {
  bool _connected = false;
  StreamSubscription<PlayerState>? _stateSub;

  bool get connected => _connected;

  final _stateController = StreamController<PlayerState>.broadcast();
  Stream<PlayerState> get playerState => _stateController.stream;

  Future<bool> connect() async {
    L.info('remote', 'Connecting to Spotify App Remote', data: {
      'client_id': SpikeSecrets.spotifyClientId,
      'redirect_uri': _redirectUri,
    });

    // On Android 10+, background apps cannot launch activities (background
    // activity launch restrictions). SpotifyAppRemote.connect(showAuthView=true)
    // tries to launch the Spotify auth activity from the background and silently
    // hangs forever on API 29+. Fix: getAccessToken() first — it launches the
    // auth UI via AuthorizationClient.openLoginActivity() from our foreground
    // Activity, which Android allows. After that, connectToSpotifyRemote() sees
    // an already-authorized session and connects without needing the auth view.
    try {
      L.info('remote', 'getAccessToken() — triggers foreground auth if needed');
      await SpotifySdk.getAccessToken(
        clientId: SpikeSecrets.spotifyClientId,
        redirectUrl: _redirectUri,
        scope: 'app-remote-control',
      );
      L.info('remote', 'getAccessToken() complete, now connecting App Remote');
    } catch (e) {
      // If the user already authorized previously, getAccessToken() may throw
      // or return immediately. Either way, attempt connectToSpotifyRemote.
      L.warn('remote', 'getAccessToken() threw (may be pre-authorized)', data: {'error': e.toString()});
    }

    try {
      final result = await SpotifySdk.connectToSpotifyRemote(
        clientId: SpikeSecrets.spotifyClientId,
        redirectUrl: _redirectUri,
      );
      _connected = result;
      L.info('remote', 'connectToSpotifyRemote result', data: {'connected': result.toString()});

      if (result) {
        _subscribToState();
      }
      return result;
    } catch (e) {
      L.error('remote', 'Connect failed', data: {'error': e.toString()});
      _connected = false;
      return false;
    }
  }

  void _subscribToState() {
    _stateSub?.cancel();
    _stateSub = SpotifySdk.subscribePlayerState().listen(
      (state) {
        final track = state.track;
        L.debug('remote', 'Player state', data: {
          'paused': state.isPaused.toString(),
          'pos_ms': state.playbackPosition.toString(),
          'track': track?.name ?? 'none',
          'artist': track?.artist.name ?? 'none',
          'duration_ms': track?.duration.toString() ?? '0',
        });
        _stateController.add(state);
      },
      onError: (Object e) {
        L.error('remote', 'State subscription error', data: {'error': e.toString()});
      },
    );
    L.info('remote', 'Subscribed to PlayerState');
  }

  Future<void> play(String spotifyUri) async {
    L.info('remote', 'play()', data: {'uri': spotifyUri});
    try {
      await SpotifySdk.play(spotifyUri: spotifyUri);
      L.info('remote', 'play() sent');
    } catch (e) {
      L.error('remote', 'play() failed', data: {'error': e.toString()});
    }
  }

  Future<void> togglePlay(bool currentlyPaused) async {
    try {
      if (currentlyPaused) {
        L.debug('remote', 'resume()');
        await SpotifySdk.resume();
      } else {
        L.debug('remote', 'pause()');
        await SpotifySdk.pause();
      }
    } catch (e) {
      L.error('remote', 'togglePlay failed', data: {'error': e.toString()});
    }
  }

  Future<void> skipNext() async {
    L.debug('remote', 'skipNext()');
    try {
      await SpotifySdk.skipNext();
    } catch (e) {
      L.error('remote', 'skipNext failed', data: {'error': e.toString()});
    }
  }

  Future<void> skipPrevious() async {
    L.debug('remote', 'skipPrevious()');
    try {
      await SpotifySdk.skipPrevious();
    } catch (e) {
      L.error('remote', 'skipPrevious failed', data: {'error': e.toString()});
    }
  }

  Future<void> disconnect() async {
    L.info('remote', 'disconnect()');
    await _stateSub?.cancel();
    try {
      await SpotifySdk.disconnect();
    } catch (e) {
      L.error('remote', 'disconnect failed', data: {'error': e.toString()});
    }
    _connected = false;
  }

  void dispose() {
    unawaited(_stateSub?.cancel());
    _stateController.close();
  }
}
