import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/featured_shows.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/screen.dart';

/// How recently an item must be published to show the "Neu" badge.
const _newBadgeMaxAge = Duration(days: 14);

// ── Hero card ───────────────────────────────────────────────────────────────

/// Large hero card for the newest featured item. Full-width cover image
/// with title, publisher, duration, and availability countdown.
///
/// Tapping navigates to the show detail screen (consistent with the
/// show grid below).
class FeaturedHeroCard extends ConsumerWidget {
  const FeaturedHeroCard({required this.item, super.key});

  final FeaturedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = ardImageUrl(item.imageUrl, width: 800);
    final existingUris = ref.watch(existingItemUrisProvider);
    final allAdded = item.parts.every(
      (p) => existingUris.contains(p.providerUri),
    );
    final isNew = DateTime.now().difference(item.publishDate) < _newBadgeMaxAge;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
      child: GestureDetector(
        onTap:
            () => context.push(
              AppRoutes.parentDiscoverShow(item.showId),
              extra: ShowDetailExtra(
                highlightEpisodeUris:
                    item.parts.map((p) => p.providerUri).toList(),
              ),
            ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(AppRadius.card),
          child: Stack(
            children: [
              // Cover image
              AspectRatio(
                aspectRatio: 16 / 9,
                child:
                    imageUrl != null
                        ? CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          color: Colors.black.withAlpha(100),
                          colorBlendMode: BlendMode.darken,
                        )
                        : const ColoredBox(
                          color: AppColors.surfaceDim,
                          child: Center(
                            child: Icon(Icons.auto_stories_rounded, size: 48),
                          ),
                        ),
              ),

              // Text overlay
              Positioned(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isNew)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '🌟 Neu',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textOnPrimary,
                          ),
                        ),
                      ),
                    if (isNew) const SizedBox(height: AppSpacing.xs),

                    // Title
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),

                    // Subtitle: publisher · parts · duration
                    Text(
                      _heroSubtitle(item),
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        color: Colors.white.withAlpha(200),
                      ),
                    ),

                    const SizedBox(height: AppSpacing.sm),

                    // Status indicator
                    Row(
                      children: [
                        const Spacer(),
                        if (allAdded)
                          const Icon(
                            Icons.check_circle,
                            color: AppColors.success,
                            size: 20,
                          )
                        else
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white70,
                            size: 24,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _heroSubtitle(FeaturedItem item) {
    final parts = <String>[];
    if (item.publisher != null) parts.add(item.publisher!);
    if (item.isMultiPart) parts.add('${item.parts.length} Teile');
    parts.add(_formatDuration(item.totalDurationSeconds));
    return parts.join(' · ');
  }
}

// ── Horizontal scroll section ───────────────────────────────────────────────

/// Horizontal scrolling section showing featured items.
class FeaturedScrollSection extends ConsumerWidget {
  const FeaturedScrollSection({required this.items, super.key});

  final List<FeaturedItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
          child: Text(
            'HÖRSPIEL-SCHÄTZE',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
            itemBuilder:
                (context, index) => _FeaturedTile(
                  item: items[index],
                ),
          ),
        ),
      ],
    );
  }
}

class _FeaturedTile extends ConsumerWidget {
  const _FeaturedTile({required this.item});

  final FeaturedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = ardImageUrl(item.imageUrl, width: 300);
    final existingUris = ref.watch(existingItemUrisProvider);
    final allAdded = item.parts.every(
      (p) => existingUris.contains(p.providerUri),
    );

    return GestureDetector(
      key: Key('featured_${item.title.hashCode}'),
      onTap:
          () => context.push(
            AppRoutes.parentDiscoverShow(item.showId),
            extra: ShowDetailExtra(
              highlightEpisodeUris:
                  item.parts.map((p) => p.providerUri).toList(),
            ),
          ),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.all(AppRadius.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (imageUrl != null)
                      CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                      )
                    else
                      const ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Center(
                          child: Icon(Icons.auto_stories_rounded),
                        ),
                      ),
                    if (allAdded)
                      ColoredBox(
                        color: Colors.black.withAlpha(120),
                        child: const Center(
                          child: Icon(
                            Icons.check_circle,
                            color: AppColors.success,
                            size: 28,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),

            // Episode title (bold, prominent)
            Text(
              item.title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),

            // Show name + duration (secondary info)
            Text(
              '${item.publisher ?? ''} · ${_tileSubtitle(item)}',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 10,
                color: AppColors.textSecondary,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  String _tileSubtitle(FeaturedItem item) {
    if (item.isMultiPart) {
      return '${item.parts.length} Teile · ${_formatDuration(item.totalDurationSeconds)}';
    }
    return _formatDuration(item.totalDurationSeconds);
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

String _formatDuration(int seconds) {
  final m = seconds ~/ 60;
  if (m < 60) return '$m Min.';
  final h = m ~/ 60;
  final rm = m % 60;
  if (rm == 0) return '${h}h';
  return '${h}h ${rm}m';
}
