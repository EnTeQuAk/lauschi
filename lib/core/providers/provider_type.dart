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
}
