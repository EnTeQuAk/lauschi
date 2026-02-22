import 'package:flutter/material.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Small provider icon badge for parent-facing card views.
///
/// Shows a Spotify or ARD logo/icon in the corner of card tiles so
/// parents can see which provider content comes from at a glance.
/// Not shown in kid UI — kids don't need to know.
class ProviderBadge extends StatelessWidget {
  const ProviderBadge({required this.provider, super.key});

  final String provider;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (provider) {
      'spotify' => (
        Icons.music_note_rounded,
        const Color(0xFF1DB954),
        'Spotify',
      ),
      'ard_audiothek' => (Icons.radio_rounded, const Color(0xFF003D7A), 'ARD'),
      'apple_music' => (Icons.apple_rounded, const Color(0xFFFA243C), 'Apple'),
      _ => (Icons.question_mark_rounded, AppColors.textSecondary, provider),
    };

    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: const BorderRadius.all(Radius.circular(6)),
        ),
        child: Icon(icon, size: 14, color: color),
      ),
    );
  }
}
