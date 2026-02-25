import 'dart:ui' show Color;

import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/database/content_importer.dart';

/// Parse a hex color string like "#FF6B00" to a [Color].
/// Returns null for invalid or missing input.
Color? parseHexColor(String? hex) {
  if (hex == null || hex.length < 7) return null;
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}

/// Convert an [ArdItem] to a [PendingCard] for import into the local database.
PendingCard ardPendingCard(ArdItem item) {
  return PendingCard(
    title: item.displayTitle,
    providerUri: item.providerUri,
    cardType: 'episode',
    provider: 'ard_audiothek',
    coverUrl: ardImageUrl(item.imageUrl),
    episodeNumber: item.episodeNumber,
    audioUrl: item.bestAudioUrl,
    durationMs: item.durationMs,
    availableUntil: item.endDate,
  );
}

/// Format a duration in seconds as a human-readable German string.
///
/// Returns e.g. "23 Min.", "1h", "1h 23m".
String formatDuration(int seconds) {
  final m = seconds ~/ 60;
  if (m < 60) return '$m Min.';
  final h = m ~/ 60;
  final rm = m % 60;
  if (rm == 0) return '${h}h';
  return '${h}h ${rm}m';
}

/// Days remaining until [endDate], or null if already expired or no date given.
int? daysUntilExpiry(DateTime? endDate) {
  if (endDate == null) return null;
  final days = endDate.difference(DateTime.now()).inDays;
  if (days < 0) return null;
  return days;
}
