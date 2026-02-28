import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_registry.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/browse_catalog_screen.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';

/// Tabbed screen for adding content from any enabled provider.
///
/// Each tab renders the provider's browse experience (embedded, no Scaffold).
/// The available tabs are driven by the [providerRegistryProvider].
///
/// When [autoAssignTileId] is set, all added content goes directly to
/// that tile. A banner above the tabs shows which tile is targeted.
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
            autoAssignTileId != null
                ? 'Folge hinzufügen'
                : 'Inhalte hinzufügen',
          ),
          bottom: TabBar(
            isScrollable: providers.length > 3,
            tabs: [
              for (final p in providers)
                Tab(
                  icon: Icon(p.type.icon, size: 18),
                  text: p.type.displayName,
                ),
            ],
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            labelStyle: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
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
        ProviderType.spotify => BrowseCatalogScreen(
          embedded: true,
          autoAssignTileId: autoAssignTileId,
        ),
        ProviderType.appleMusic => _ComingSoon(type: type),
        ProviderType.tidal => _ComingSoon(type: type),
      };
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
