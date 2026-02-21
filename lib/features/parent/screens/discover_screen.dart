import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/featured_shows.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/featured_section.dart';

/// Browse ARD Audiothek kids content. Featured items on top, then the
/// full kids show grid below.
class DiscoverScreen extends ConsumerWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showsAsync = ref.watch(_kidsShowsProvider);
    final featuredAsync = ref.watch(featuredItemsProvider);

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Entdecken'),
      ),
      body: showsAsync.when(
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
                    onPressed: () {
                      ref
                        ..invalidate(_kidsShowsProvider)
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
                  loading: () => const Padding(
                    padding: EdgeInsets.all(AppSpacing.lg),
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (featured) {
                    if (featured.isEmpty) return const SizedBox.shrink();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Hero card — newest featured item
                        FeaturedHeroCard(item: featured.first),
                        const SizedBox(height: AppSpacing.lg),

                        // Horizontal scroll — remaining items
                        if (featured.length > 1)
                          FeaturedScrollSection(
                            items: featured.sublist(1),
                          ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                ),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: AppSpacing.md,
                    crossAxisSpacing: AppSpacing.md,
                    childAspectRatio: 0.7,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _ShowCard(show: shows[index]),
                    childCount: shows.length,
                  ),
                ),
              ),

              // Bottom padding
              const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xl)),
            ],
          );
        },
      ),
    );
  }
}

class _ShowCard extends StatelessWidget {
  const _ShowCard({required this.show});

  final ArdProgramSet show;

  @override
  Widget build(BuildContext context) {
    final imageUrl = ardImageUrl(show.imageUrl, width: 300);

    return GestureDetector(
      onTap: () => context.push(AppRoutes.parentDiscoverShow(show.id)),
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
                        width: double.infinity,
                        height: double.infinity,
                        placeholder:
                            (_, _) => _Placeholder(title: show.title),
                        errorWidget:
                            (_, _, _) => _Placeholder(title: show.title),
                      )
                      : _Placeholder(title: show.title),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            show.title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          if (show.publisher != null)
            Text(
              show.publisher!,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            '${show.numberOfElements} Folgen',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10,
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final hue = (title.hashCode % 360).abs().toDouble();
    return ColoredBox(
      color: HSLColor.fromAHSL(1, hue, 0.3, 0.25).toColor(),
      child: Center(
        child: Icon(
          Icons.radio_rounded,
          color: HSLColor.fromAHSL(1, hue, 0.4, 0.5).toColor(),
          size: 32,
        ),
      ),
    );
  }
}

final _kidsShowsProvider = FutureProvider.autoDispose<List<ArdProgramSet>>(
  (ref) => ref.watch(ardApiProvider).getKidsShows(),
);
