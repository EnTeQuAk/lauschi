import 'dart:ui' show Color;

import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/database/content_importer.dart';

/// Parse a 6-digit RGB hex string like "#FF6B00" to an opaque [Color].
/// Returns null for missing input or anything that isn't exactly six hex
/// digits, so an 8-digit ARGB value is rejected rather than shifted into
/// the wrong channels.
Color? parseHexColor(String? hex) {
  if (hex == null) return null;
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}

/// Convert an [ArdItem] to a [PendingCard] for import into the local database.
///
/// ARD's `episodeNumber` stays out: it is the part within a multi-part
/// story, not a number across the show, and as an episode number it would
/// sort every story's part 1 first. A show's episodes sort by
/// [PendingCard.publishedAt] instead.
PendingCard ardPendingCard(ArdItem item) {
  return PendingCard(
    title: item.displayTitle,
    providerUri: item.providerUri,
    cardType: 'episode',
    coverUrl: ardImageUrl(item.imageUrl),
    audioUrl: item.bestAudioUrl,
    durationMs: item.durationMs,
    publishedAt: item.publishDate,
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
