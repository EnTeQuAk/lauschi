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
  playbackCommandFailed,

  /// Spotify Web Playback SDK has no device ID. Either the SDK never
  /// connected or the device went stale and reconnect failed.
  spotifyNotConnected,

  /// Spotify auth token refresh failed. User needs to re-authenticate.
  spotifyAuthExpired,

  /// Spotify account issue (e.g. Premium subscription lapsed).
  spotifyAccountError,

  /// Network connectivity issue reaching Spotify servers.
  spotifyNetworkError,

  /// Spotify SDK reported a playback-level error (distinct from network
  /// or auth). Typically transient.
  spotifyPlaybackFailed,

  /// Spotify device was valid but went stale during playback, and
  /// reconnect did not recover it.
  spotifyConnectionLost,

  /// TileItem has no audio URL. Should not happen if catalog validation
  /// is correct.
  noAudioUrl;

  /// Visual category for the error dialog. Determines which mascot,
  /// headline, and action button to show.
  ErrorCategory get category => switch (this) {
    contentUnavailable => ErrorCategory.gone,
    spotifyAuthExpired || spotifyAccountError => ErrorCategory.parentAction,
    _ => ErrorCategory.oops,
  };

  /// Whether retrying the same action could work (transient errors).
  bool get isRetryable => switch (this) {
    playbackFailed ||
    playbackCommandFailed ||
    spotifyNotConnected ||
    spotifyNetworkError ||
    spotifyPlaybackFailed ||
    spotifyConnectionLost ||
    noAudioUrl => true,
    contentUnavailable || spotifyAuthExpired || spotifyAccountError => false,
  };

  /// Technical error message shown in small text for parents.
  String get message => switch (this) {
    contentUnavailable => 'Inhalt nicht mehr verfügbar',
    playbackFailed => 'Wiedergabe fehlgeschlagen',
    playbackCommandFailed => 'Steuerung fehlgeschlagen',
    spotifyNotConnected => 'Spotify nicht verbunden',
    spotifyAuthExpired => 'Spotify-Verbindung abgelaufen',
    spotifyAccountError => 'Spotify-Konto-Problem',
    spotifyNetworkError => 'Keine Verbindung zu Spotify',
    spotifyPlaybackFailed => 'Wiedergabe fehlgeschlagen',
    spotifyConnectionLost => 'Spotify-Verbindung verloren',
    noAudioUrl => 'Keine Audio-URL verfügbar',
  };
}

/// Visual category grouping errors by mascot illustration and tone.
enum ErrorCategory {
  /// Transient connection or playback issue. Confused fox, "try again".
  oops(
    asset: 'assets/images/branding/lauschi-confused.png',
    fallbackEmoji: '🤔',
    headline: 'Hoppla!',
    subtitle: 'Das hat gerade nicht geklappt.\nProbier es nochmal!',
    actionLabel: 'Nochmal probieren',
  ),

  /// Content permanently gone (expired, pulled). Fox waving goodbye.
  gone(
    asset: 'assets/images/branding/lauschi-goodbye.png',
    fallbackEmoji: '🐦',
    headline: 'Weggeflogen!',
    subtitle: 'Diese Geschichte gibt es\nleider nicht mehr.',
    actionLabel: 'Zurück',
  ),

  /// Auth or account issue. Parent needs to act. Sleeping fox.
  parentAction(
    asset: 'assets/images/branding/lauschi-sleeping.png',
    fallbackEmoji: '😴',
    headline: 'Lauschi schläft…',
    subtitle: 'Frag Mama oder Papa,\ndie können das reparieren!',
    actionLabel: 'Zurück',
  );

  const ErrorCategory({
    required this.asset,
    required this.fallbackEmoji,
    required this.headline,
    required this.subtitle,
    required this.actionLabel,
  });

  /// Path to the mascot illustration. Falls back to [fallbackEmoji]
  /// if the asset doesn't exist yet (mascots being illustrated).
  final String asset;

  /// Emoji shown while the mascot PNGs aren't ready yet.
  final String fallbackEmoji;

  /// Kid-friendly headline in large text.
  final String headline;

  /// Short explanation a child can understand.
  final String subtitle;

  /// Primary action button label.
  final String actionLabel;
}
