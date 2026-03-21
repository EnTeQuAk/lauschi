/// Apple Music configuration for MusicKit JS WebView playback.
abstract final class AppleMusicConfig {
  // Remote URL required: MusicKit JS needs an HTTPS origin for
  // Widevine EME (DRM). Local assets (file://) don't work.
  // A copy is bundled at assets/apple_music_player.html for reference.
  //
  // Cache-buster query param forces WebView to fetch the latest version.
  // Bump this when deploying player HTML changes during development.
  static const playerUrl =
      'https://tuneloopbot.webshox.org/lauschi/apple_music_player.html?v=8';
}
