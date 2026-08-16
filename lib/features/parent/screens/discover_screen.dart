import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/ard_providers.dart';
import 'package:lauschi/core/ard/featured_shows.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/screen.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';
import 'package:lauschi/features/parent/widgets/featured_section.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// Browse ARD Audiothek kids content. Featured items on top, then the
/// full kids show grid below.
///
/// When [embedded] is true, returns just the body content without
/// Scaffold/AppBar (for use inside tabbed containers).
class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({
    super.key,
    this.embedded = false,
    this.autoAssignTileId,
  });

  final bool embedded;

  /// When set, episodes added from show detail screens go directly
  /// to this tile instead of creating a group by show title.
  final String? autoAssignTileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Log a failed featured load once per transition, not on every rebuild
    // (the error builder below runs on every frame it's shown).
    ref.listen(featuredItemsProvider, (prev, next) {
      if (next is AsyncError && prev is! AsyncError) {
        Log.error('Discover', 'Featured items failed', exception: next.error);
      }
    });

    final showsAsync = ref.watch(ardKidsShowsProvider);
    final featuredAsync = ref.watch(featuredItemsProvider);

    final body = showsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (e, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  color: AppColors.textSecondary,
                  size: 48,
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'ARD Audiothek nicht erreichbar',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  key: const Key('discover_retry'),
                  onPressed: () {
                    ref
                      ..invalidate(ardKidsShowsProvider)
                      ..invalidate(featuredItemsProvider);
                  },
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
      data: (shows) {
        if (shows.isEmpty) {
          return const Center(
            child: Text(
              'Keine Sendungen gefunden.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }

        return CustomScrollView(
          slivers: [
            // Featured section (loads independently)
            SliverToBoxAdapter(
              child: featuredAsync.when(
                loading:
                    () => const Padding(
                      padding: EdgeInsets.all(AppSpacing.lg),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                error: (_, _) => const SizedBox.shrink(),
                data: (featured) {
                  if (featured.isEmpty) return const SizedBox.shrink();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FeaturedHeroCard(item: featured.first),
                      const SizedBox(height: AppSpacing.lg),
                      if (featured.length > 1)
                        FeaturedScrollSection(items: featured.sublist(1)),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  );
                },
              ),
            ),

            // Section header
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenH,
                  vertical: AppSpacing.sm,
                ),
                child: Text(
                  'ALLE SENDUNGEN',
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),

            // Show grid
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: AppSpacing.md,
                  crossAxisSpacing: AppSpacing.md,
                  childAspectRatio: 0.7,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _ShowCard(
                    show: shows[index],
                    autoAssignTileId: autoAssignTileId,
                  ),
                  childCount: shows.length,
                ),
              ),
            ),

            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.screenH,
                  AppSpacing.lg,
                  AppSpacing.screenH,
                  AppSpacing.xl,
                ),
                child: Text(
                  'Inhalte der ARD Audiothek',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 11,
                    color: AppColors.textHint,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (embedded) {
      return ColoredBox(
        color: AppColors.parentBackground,
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Entdecken'),
      ),
      body: body,
    );
  }
}

class _ShowCard extends StatelessWidget {
  const _ShowCard({required this.show, this.autoAssignTileId});

  final ArdProgramSet show;
  final String? autoAssignTileId;

  @override
  Widget build(BuildContext context) {
    final imageUrl = ardImageUrl(show.imageUrl, width: 300);
    final broadcaster = show.organizationName ?? show.publisher;
    final count = show.numberOfElements;
    final folgen = '$count ${count == 1 ? 'Folge' : 'Folgen'}';
    final subtitle = broadcaster != null ? '$broadcaster · $folgen' : folgen;

    return GestureDetector(
      onTap:
          () => context.push(
            AppRoutes.parentDiscoverShow(show.id),
            extra: ShowDetailExtra(autoAssignTileId: autoAssignTileId),
          ),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.card),
              child:
                  imageUrl != null
                      ? CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 400,
                        width: double.infinity,
                        height: double.infinity,
                        placeholder:
                            (_, _) => CatalogPlaceholder(
                              title: show.title,
                              icon: Icons.radio_rounded,
                            ),
                        errorWidget:
                            (_, _, _) => CatalogPlaceholder(
                              title: show.title,
                              icon: Icons.radio_rounded,
                            ),
                      )
                      : CatalogPlaceholder(
                        title: show.title,
                        icon: Icons.radio_rounded,
                      ),
            ),
          ),
          TileLabel(title: show.title, subtitle: subtitle),
        ],
      ),
    );
  }
}
