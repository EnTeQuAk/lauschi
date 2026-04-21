import 'package:flutter/material.dart';

/// Supported audio content providers.
///
/// Each provider has a stable string [value] used in the database and
/// catalog YAML. The enum is the single source of truth for provider
/// identity throughout the app.
enum ProviderType {
  spotify('spotify'),
  ardAudiothek('ard_audiothek'),
  appleMusic('apple_music'),
  tidal('tidal');

  const ProviderType(this.value);

  /// Stable string for DB storage and YAML keys.
  final String value;

  /// Human-readable name for parent-facing UI.
  String get displayName => switch (this) {
    spotify => 'Spotify',
    ardAudiothek => 'ARD Audiothek',
    appleMusic => 'Apple Music',
    tidal => 'Tidal',
  };

  /// Icon for provider badges and settings.
  IconData get icon => switch (this) {
    spotify => Icons.music_note_rounded,
    ardAudiothek => Icons.radio_rounded,
    appleMusic => Icons.apple_rounded,
    tidal => Icons.waves_rounded,
  };

  /// SVG asset path for branded provider logos.
  String? get svgAsset => switch (this) {
    spotify => 'assets/images/icons/spotify.svg',
    ardAudiothek => 'assets/images/icons/ard_audiothek.svg',
    appleMusic => 'assets/images/icons/apple_music.svg',
    tidal => null,
  };

  /// Brand color for badges and UI accents.
  Color get color => switch (this) {
    spotify => const Color(0xFF1DB954),
    ardAudiothek => const Color(0xFF003D7A),
    appleMusic => const Color(0xFFFA243C),
    tidal => const Color(0xFF000000),
  };

  /// Parse from DB/YAML string. Throws on unknown values.
  static ProviderType fromString(String s) => values.firstWhere(
    (e) => e.value == s,
    orElse: () => throw ArgumentError('Unknown provider: $s'),
  );

  // ── Provider URI helpers ──────────────────────────────────────────

  /// URI prefix for this provider (e.g. 'spotify', 'apple_music').
  String get _uriPrefix => switch (this) {
    spotify => 'spotify',
    ardAudiothek => 'ard',
    appleMusic => 'apple_music',
    tidal => 'tidal',
  };

  /// Build a canonical album URI for DB storage.
  /// e.g. 'spotify:album:4aawyAB9vmqN3uQ7FjRGTy'
  String albumUri(String albumId) => '$_uriPrefix:album:$albumId';

  /// Build a canonical track URI for playback state.
  /// e.g. 'apple_music:track:1686062068'
  String trackUri(String trackId) => '$_uriPrefix:track:$trackId';

  /// Extract the ID from a provider URI. Returns null if format doesn't match.
  /// e.g. 'apple_music:album:123' → '123'
  static String? extractId(String uri) {
    final parts = uri.split(':');
    return parts.length == 3 ? parts[2] : null;
  }
}
