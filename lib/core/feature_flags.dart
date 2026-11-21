/// Compile-time feature flags set via `--dart-define` or
/// `--dart-define-from-file=.env`.
///
/// These are `const` — the compiler tree-shakes unreachable branches.
abstract final class FeatureFlags {
  /// Spotify integration. Requires a SPOTIFY_CLIENT_ID in the environment.
  /// When false, all Spotify UI, auth, bridge, and playback code is gated off.
  static const enableSpotify = bool.fromEnvironment('ENABLE_SPOTIFY');

  /// Apple Music integration via MusicKit. The app holds no MusicKit key:
  /// on iOS MusicKit makes the developer token, on Android
  /// `AppleMusicDeveloperToken` fetches one the lauschi server signs. When
  /// false, Apple Music UI and auth are gated off.
  static const enableAppleMusic = bool.fromEnvironment('ENABLE_APPLE_MUSIC');

  /// Sentry error tracking and diagnostics UI in parent settings.
  /// When false, Sentry is never initialized and the diagnostics section
  /// is hidden from settings. Intended for TestFlight/Firebase testers only,
  /// not public store builds.
  static const enableSentry = bool.fromEnvironment('ENABLE_SENTRY');
}
