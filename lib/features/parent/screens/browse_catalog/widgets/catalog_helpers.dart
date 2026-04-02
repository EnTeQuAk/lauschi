import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/apple_music/apple_music_catalog_source.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_catalog_source.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';

// ── Search result processing ────────────────────────────────────────────────

/// Sort album indices so catalog-matched albums come first.
/// Preserves the provider's relevance order within each group.
List<int> sortByCatalogMatch(List<CatalogMatch?> matches, int count) {
  return List.generate(count, (i) => i)..sort((a, b) {
    final aMatch = a < matches.length && matches[a] != null;
    final bMatch = b < matches.length && matches[b] != null;
    if (aMatch != bMatch) return aMatch ? -1 : 1;
    return 0;
  });
}

/// Partition album indices into those matching hero series and the rest.
({List<int> matching, List<int> nonMatching}) partitionByHeroSeries(
  List<CatalogMatch?> matches,
  Set<String> heroSeriesIds,
  int count,
) {
  final matching = <int>[];
  final nonMatching = <int>[];
  for (var i = 0; i < count; i++) {
    final isHeroMatch =
        i < matches.length &&
        matches[i] != null &&
        heroSeriesIds.contains(matches[i]!.series.id);
    (isHeroMatch ? matching : nonMatching).add(i);
  }
  return (matching: matching, nonMatching: nonMatching);
}

// ── UI helpers ──────────────────────────────────────────────────────────────

/// Hue-based placeholder for album art that hasn't loaded yet.
class CatalogPlaceholder extends StatelessWidget {
  const CatalogPlaceholder({required this.title, super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, hue, 0.3, 0.25).toColor(),
        borderRadius: const BorderRadius.all(AppRadius.card),
      ),
      child: Center(
        child: Icon(
          Icons.headphones_rounded,
          color: HSLColor.fromAHSL(1, hue, 0.4, 0.5).toColor(),
          size: 32,
        ),
      ),
    );
  }
}

/// Format milliseconds as "m:ss".
String formatCatalogDuration(int ms) {
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Fetches album covers for all episodes in a single catalog series.
///
/// Keyed on a comma-joined string of album IDs. Dart lists don't have
/// deep equality, so a list key would restart the fetch on every rebuild.
///
/// Key format: "provider:id1,id2,id3" where provider is the ProviderType value
/// and IDs are comma-separated.
final albumCoversProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>(
      (ref, key) async {
        if (key.isEmpty) return {};

        final colonIdx = key.indexOf(':');
        if (colonIdx < 0) return {};

        final providerValue = key.substring(0, colonIdx);
        final joinedIds = key.substring(colonIdx + 1);
        if (joinedIds.isEmpty) return {};

        final albumIds = joinedIds.split(',');
        final source = resolveSource(ref, providerValue);
        if (source == null) return {};

        // ignore: unnecessary_await_in_return, async needed for early returns
        return await source.getAlbumCovers(albumIds);
      },
    );

/// Fetches a single album's cover URL from the provider API.
///
/// Key format: "provider_value:album_id". Each card watches its own
/// cover independently, so covers appear as each card becomes visible.
/// Riverpod deduplicates identical requests.
final albumCoverProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, key) async {
    final colonIdx = key.indexOf(':');
    if (colonIdx < 0) return null;

    final providerValue = key.substring(0, colonIdx);
    final albumId = key.substring(colonIdx + 1);
    if (albumId.isEmpty) return null;

    final source = resolveSource(ref, providerValue);
    if (source == null) return null;

    // Cancel pending cover request when card scrolls off screen.
    ref.onDispose(() => source.cancelCover(albumId));

    final covers = await source.getAlbumCovers([albumId]);
    return covers[albumId];
  },
);

/// Build a CatalogSource from session state.
///
/// Pure function: takes the session objects directly so it works from
/// both provider [Ref] and widget [WidgetRef] call sites.
CatalogSource? buildSource(
  String providerValue,
  SpotifySessionState spotifyState,
  SpotifySession spotifySession,
  AppleMusicState appleMusicState,
  AppleMusicSession appleMusicSession,
) {
  if (providerValue == ProviderType.spotify.value) {
    if (spotifyState is! SpotifyAuthenticated) return null;
    return SpotifyCatalogSource(spotifySession.api);
  }
  if (providerValue == ProviderType.appleMusic.value) {
    if (appleMusicState is! AppleMusicAuthenticated) return null;
    return AppleMusicCatalogSource(appleMusicSession.api);
  }
  return null;
}

/// Resolve a CatalogSource from a provider value string via Ref.
CatalogSource? resolveSource(Ref ref, String providerValue) {
  final spotifyState = ref.watch(spotifySessionProvider);
  final appleMusicState = ref.watch(appleMusicSessionProvider);
  return buildSource(
    providerValue,
    spotifyState,
    ref.read(spotifySessionProvider.notifier),
    appleMusicState,
    ref.read(appleMusicSessionProvider.notifier),
  );
}

/// Resolve a CatalogSource from a provider value string via WidgetRef.
CatalogSource? resolveSourceWidget(WidgetRef ref, String providerValue) {
  return buildSource(
    providerValue,
    ref.read(spotifySessionProvider),
    ref.read(spotifySessionProvider.notifier),
    ref.read(appleMusicSessionProvider),
    ref.read(appleMusicSessionProvider.notifier),
  );
}
