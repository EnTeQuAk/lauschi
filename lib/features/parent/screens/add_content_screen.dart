import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lauschi/core/apple_music/apple_music_catalog_source.dart';
import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_registry.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_catalog_source.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/browse_catalog_screen.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';

/// Screen for discovering and adding content from available providers.
///
/// Shows provider cards as entry points. ARD Audiothek is always available
/// and visually prominent. Spotify and Apple Music appear only when their
/// feature flags are enabled.
///
/// When [autoAssignTileId] is set, all added content goes directly to
/// that tile.
class AddContentScreen extends ConsumerWidget {
  const AddContentScreen({super.key, this.initialTab, this.autoAssignTileId});

  /// Which provider tab to show initially. Defaults to the first tab.
  final ProviderType? initialTab;

  /// When set, content is added directly to this tile.
  final String? autoAssignTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(providerRegistryProvider);

    // Determine initial tab index.
    final initialIndex =
        initialTab != null
            ? providers
                .indexWhere((p) => p.type == initialTab)
                .clamp(0, providers.length - 1)
            : 0;

    return DefaultTabController(
      length: providers.length,
      initialIndex: initialIndex,
      child: Scaffold(
        backgroundColor: AppColors.parentBackground,
        appBar: AppBar(
          backgroundColor: AppColors.parentBackground,
          title: Text(
            autoAssignTileId != null ? 'Folge hinzufügen' : 'Inhalte entdecken',
          ),
          bottom: _ProviderTabBar(providers: providers),
        ),
        body: Column(
          children: [
            if (autoAssignTileId != null)
              _AutoAssignBanner(tileId: autoAssignTileId!),
            Expanded(
              child: TabBarView(
                children: [
                  for (final p in providers) _tabBody(p.type, autoAssignTileId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _tabBody(ProviderType type, String? autoAssignTileId) =>
      switch (type) {
        ProviderType.ardAudiothek => DiscoverScreen(
          embedded: true,
          autoAssignTileId: autoAssignTileId,
        ),
        ProviderType.spotify => _SpotifyTab(
          autoAssignTileId: autoAssignTileId,
        ),
        ProviderType.appleMusic => _AppleMusicTab(
          autoAssignTileId: autoAssignTileId,
        ),
        ProviderType.tidal => _ComingSoon(type: type),
      };
}

/// Tab bar with provider logos instead of plain text labels.
class _ProviderTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _ProviderTabBar({required this.providers});

  final List<ProviderInfo> providers;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return TabBar(
      isScrollable: providers.length > 3,
      tabs: [for (final p in providers) Tab(child: _ProviderTabLabel(p))],
      labelColor: AppColors.textPrimary,
      unselectedLabelColor: AppColors.textSecondary,
      indicatorColor: AppColors.primary,
      dividerHeight: 0,
    );
  }
}

/// Single tab label: logo + name, styled per provider.
class _ProviderTabLabel extends StatelessWidget {
  const _ProviderTabLabel(this.info);

  final ProviderInfo info;

  @override
  Widget build(BuildContext context) {
    final logo = _providerLogo(info.type);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (logo != null) ...[logo, const SizedBox(width: 6)],
        if (logo == null) ...[
          Icon(info.type.icon, size: 18),
          const SizedBox(width: 6),
        ],
        Text(
          info.type.displayName,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Returns an SVG logo widget for providers that have one.
Widget? _providerLogo(ProviderType type, {double size = 20}) {
  final path = switch (type) {
    ProviderType.ardAudiothek => 'assets/images/icons/ard_audiothek.svg',
    ProviderType.spotify => 'assets/images/icons/spotify.svg',
    ProviderType.appleMusic => 'assets/images/icons/apple_music.svg',
    _ => null,
  };
  if (path == null) return null;
  return SvgPicture.asset(
    path,
    width: size,
    height: size,
    colorFilter:
        type == ProviderType.ardAudiothek
            ? ColorFilter.mode(type.color, BlendMode.srcIn)
            : null,
  );
}

/// Banner showing which tile content will be added to.
class _AutoAssignBanner extends ConsumerWidget {
  const _AutoAssignBanner({required this.tileId});

  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tilesAsync = ref.watch(allTilesProvider);
    final tileName = tilesAsync.whenOrNull(
      data: (tiles) {
        final tile = tiles.where((t) => t.id == tileId).firstOrNull;
        return tile?.title;
      },
    );

    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.layers_rounded,
            size: 16,
            color: AppColors.primary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              tileName != null
                  ? 'Folgen werden direkt zu »$tileName« hinzugefügt'
                  : 'Folgen werden direkt zur Kachel hinzugefügt',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotifyTab extends ConsumerWidget {
  const _SpotifyTab({this.autoAssignTileId});

  final String? autoAssignTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionState = ref.watch(spotifySessionProvider);

    return switch (sessionState) {
      SpotifyLoading() => const _ProviderLoadingIndicator(
        type: ProviderType.spotify,
      ),
      SpotifyAuthenticated() => BrowseCatalogScreen(
        catalogSource: SpotifyCatalogSource(
          ref.read(spotifySessionProvider.notifier).api,
        ),
        embedded: true,
        autoAssignTileId: autoAssignTileId,
      ),
      SpotifyUnauthenticated() || SpotifyError() => _ProviderConnectPrompt(
        type: ProviderType.spotify,
        description:
            'Mit Spotify bekommst du Zugriff auf tausende '
            'Hörspiele und Kindermusik.',
        requirement: 'Du brauchst ein Spotify Premium Abo.',
        onConnect: () async {
          await ref.read(spotifySessionProvider.notifier).login();
        },
      ),
    };
  }
}

class _AppleMusicTab extends ConsumerWidget {
  const _AppleMusicTab({this.autoAssignTileId});

  final String? autoAssignTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionState = ref.watch(appleMusicSessionProvider);

    return switch (sessionState) {
      AppleMusicLoading() => const _ProviderLoadingIndicator(
        type: ProviderType.appleMusic,
      ),
      AppleMusicAuthenticated() => BrowseCatalogScreen(
        embedded: true,
        autoAssignTileId: autoAssignTileId,
        catalogSource: AppleMusicCatalogSource(
          ref.read(appleMusicSessionProvider.notifier).api,
        ),
      ),
      AppleMusicUnauthenticated() => _ProviderConnectPrompt(
        type: ProviderType.appleMusic,
        description:
            'Mit Apple Music bekommst du Zugriff auf tausende '
            'Hörspiele: Die drei ???, TKKG, Bibi Blocksberg '
            'und viele mehr.',
        requirement:
            'Du brauchst ein Apple Music Abo und die '
            'Apple Music App auf deinem Gerät.',
        onConnect: () async {
          await ref.read(appleMusicSessionProvider.notifier).connect();
        },
      ),
    };
  }
}

/// Loading indicator shown while checking provider auth state.
class _ProviderLoadingIndicator extends StatelessWidget {
  const _ProviderLoadingIndicator({required this.type});

  final ProviderType type;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.parentBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${type.displayName} wird verbunden…',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Connect prompt for providers that require auth.
///
/// Shows the provider logo prominently, a description, and a connect button
/// in the provider's brand color.
class _ProviderConnectPrompt extends StatelessWidget {
  const _ProviderConnectPrompt({
    required this.type,
    required this.description,
    required this.onConnect,
    this.requirement,
  });

  final ProviderType type;
  final String description;
  final String? requirement;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final logo = _providerLogo(type, size: 56);

    return ColoredBox(
      color: AppColors.parentBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (logo != null)
                logo
              else
                Icon(type.icon, size: 56, color: type.color),
              const SizedBox(height: AppSpacing.md),
              Text(
                '${type.displayName} verbinden',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              if (requirement != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  requirement!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: onConnect,
                icon:
                    logo != null
                        ? SizedBox(
                          width: 20,
                          height: 20,
                          child:
                              _providerLogo(type) ?? Icon(type.icon, size: 20),
                        )
                        : Icon(type.icon),
                label: Text('Mit ${type.displayName} verbinden'),
                style: FilledButton.styleFrom(
                  backgroundColor: type.color,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                  textStyle: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.type});

  final ProviderType type;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.parentBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(type.icon, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.md),
            Text(
              '${type.displayName} kommt bald',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
