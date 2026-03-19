/// Apple Music / MusicKit configuration.
///
/// The developer token is only needed on Android. On iOS, MusicKit
/// auto-generates it from the app's entitlements.
///
/// Generate the token with: `mise run apple-music-token`
/// Then add it to .env.app as `APPLE_MUSIC_DEVELOPER_TOKEN=...`.
abstract final class AppleMusicConfig {
  /// Pre-generated JWT developer token for Android.
  /// Compiled in via `--dart-define-from-file=.env.app`.
  static const developerToken =
      String.fromEnvironment('APPLE_MUSIC_DEVELOPER_TOKEN');

  /// Team ID from Apple Developer account.
  static const teamId = 'QDF8U52UF4';

  /// MusicKit private key ID.
  static const keyId = 'PWHK2R76T9';
}
