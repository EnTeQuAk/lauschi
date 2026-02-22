/// Clean up album/episode titles for kid-facing display.
///
/// Strips boilerplate that Spotify publishers add to album titles:
/// - "Folge N: " / "Episode N: " prefix (redundant when number shown)
/// - "(Das Original-Hörspiel zur TV-Serie)" and similar suffixes
/// - "[Original-Hörspiel zur TV-Kinderserie]" bracket variants
/// - "(Ungekürzt)" / "(Gekürzt)" audiobook markers
///
/// Returns the meaningful part of the title. Falls back to [raw] if
/// cleaning would produce an empty string.
String cleanEpisodeTitle(String raw, {int? episodeNumber}) {
  var t = raw;

  // Strip parenthetical/bracket suffixes containing common boilerplate.
  // These patterns appear at the END of titles.
  for (final pattern in _suffixPatterns) {
    t = t.replaceAll(pattern, '');
  }

  // Strip "Folge N: " / "Folge N - " prefix when we show number separately.
  if (episodeNumber != null) {
    t = t.replaceAll(_folgePrefix, '');
    t = t.replaceAll(_episodePrefix, '');
  }

  t = t.trim();
  return t.isEmpty ? raw : t;
}

/// Try to extract an episode number from a title string.
///
/// Priority: "Folge N", "Episode N", leading "NNN/" (TKKG/Fünf Freunde).
/// Returns null if no recognizable pattern found.
int? parseEpisodeNumber(String title) {
  for (final pattern in _numberPatterns) {
    final match = pattern.firstMatch(title);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

// -- Private patterns --------------------------------------------------------

// Suffix patterns to strip (order matters — more specific first).
final _suffixPatterns = [
  // Parenthetical with "Hörspiel" anywhere inside.
  // Catches: (Das Original-Hörspiel zur TV-Serie), (Hörspiel),
  // (Das Hörspiel zum Film), (Vier Hörspiele), etc.
  RegExp(r'\s*\([^)]*[Hh]örspiel[^)]*\)\s*$'),
  // Square bracket variant: [Original-Hörspiel zur TV-Kinderserie]
  RegExp(r'\s*\[[^\]]*[Hh]örspiel[^\]]*\]\s*$'),
  // Soundtrack: (Der Original-Soundtrack zum Kinofilm)
  RegExp(r'\s*\([^)]*[Ss]oundtrack[^)]*\)\s*$'),
  // Audiobook length markers: (Ungekürzt), (Gekürzt), (ungekürzt)
  RegExp(r'\s*\([Uu]ngekürzt\)\s*$'),
  RegExp(r'\s*\([Gg]ekürzt\)\s*$'),
];

final _folgePrefix = RegExp(r'^[Ff]olge\s+\d+\s*[:\-–—]\s*');
final _episodePrefix = RegExp(r'^[Ee]pisode\s+\d+\s*[:\-–—]\s*');

// Patterns for extracting episode numbers from raw titles.
final _numberPatterns = [
  // "Folge 38: ..." or "Folge 38 - ..."
  RegExp(r'^[Ff]olge\s+(\d+)'),
  // "Episode 12: ..."
  RegExp(r'^[Ee]pisode\s+(\d+)'),
  // "031/Rückkehr der Saurier" (TKKG, Fünf Freunde, etc.)
  RegExp(r'^(\d{2,3})/'),
];
