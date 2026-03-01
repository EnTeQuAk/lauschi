/// Compile-time feature flags set via `--dart-define` or
/// `--dart-define-from-file=.env`.
///
/// These are `const` — the compiler tree-shakes unreachable branches.
abstract final class FeatureFlags {
  /// Spotify integration. Requires a SPOTIFY_CLIENT_ID in the environment.
  /// When false, all Spotify UI, auth, bridge, and playback code is gated off.
  static const enableSpotify = bool.fromEnvironment('ENABLE_SPOTIFY');
}
