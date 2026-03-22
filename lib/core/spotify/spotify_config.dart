/// Spotify API configuration.
///
/// Client ID is compiled in via `--dart-define=SPOTIFY_CLIENT_ID=...`.
/// Never hardcode secrets — the client ID is public (PKCE flow), but keeping
/// it out of source prevents accidental leaks of future config values.
abstract final class SpotifyConfig {
  static const clientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');

  static const redirectUri = 'lauschi://callback';

  // Remote URL required: Spotify Web Playback SDK needs an HTTPS origin for
  // Widevine EME. Local assets (file://, flutter-asset://) don't work.
  // A copy is bundled at assets/player.html for reference.
  static const playerUrl = 'https://auth.lauschi.app/player.html';

  static const scopes = [
    'streaming',
    'user-read-playback-state',
    'user-modify-playback-state',
    'user-read-currently-playing',
    'user-read-private',
    'user-read-email', // Web Playback SDK validates this during connection
  ];

  /// Market for search results and content availability.
  static const market = 'DE';
}
