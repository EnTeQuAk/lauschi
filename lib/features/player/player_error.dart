/// Typed error states for the player subsystem.
///
/// Backend code sets these; UI code maps them to user-facing text.
/// This avoids scattering German strings through infrastructure code
/// and lets tests assert on typed values instead of string matching.
enum PlayerError {
  /// Audio content expired or removed from CDN (e.g. ARD availability
  /// window ended, Spotify track pulled).
  contentUnavailable,

  /// Generic playback failure (catch-all for unexpected exceptions
  /// during play startup).
  playbackFailed,

  /// A playback control command (pause/resume/seek/skip) failed.
  controlFailed,

  /// Spotify Web Playback SDK has no device ID. Either the SDK never
  /// connected or the device went stale and reconnect failed.
  spotifyNotConnected,

  /// Spotify auth token refresh failed. User needs to re-authenticate.
  spotifyAuthExpired,

  /// Spotify account issue (e.g. Premium subscription lapsed).
  spotifyAccountError,

  /// Network connectivity issue reaching Spotify servers.
  spotifyNetworkError,

  /// Spotify device was valid but went stale during playback, and
  /// reconnect did not recover it.
  spotifyConnectionLost,

  /// TileItem has no audio URL. Should not happen if catalog validation
  /// is correct.
  noAudioUrl;

  /// Whether this error should show the kid-friendly "story flew away"
  /// screen instead of the normal player UI.
  bool get showsUnavailableScreen => this == contentUnavailable;

  /// User-facing message for error banners and snackbars.
  /// German text lives here (single source of truth), not scattered
  /// through backend code.
  String get message => switch (this) {
    contentUnavailable =>
      'Diese Geschichte ist leider nicht mehr verfügbar',
    playbackFailed => 'Wiedergabe fehlgeschlagen',
    controlFailed => 'Steuerung fehlgeschlagen',
    spotifyNotConnected => 'Spotify nicht verbunden',
    spotifyAuthExpired =>
      'Spotify-Verbindung abgelaufen, bitte neu verbinden',
    spotifyAccountError => 'Spotify-Konto-Problem, bitte Abo prüfen',
    spotifyNetworkError => 'Keine Verbindung zu Spotify',
    spotifyConnectionLost => 'Spotify-Verbindung verloren',
    noAudioUrl => 'Keine Audio-URL verfügbar',
  };
}
