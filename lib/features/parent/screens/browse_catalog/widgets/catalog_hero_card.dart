import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/browse_catalog/widgets/catalog_helpers.dart';

/// Compact hero card shown in search results when an album matches
/// a curated catalog series.
class CatalogHeroCard extends ConsumerWidget {
  const CatalogHeroCard({
    required this.series,
    required this.provider,
    required this.addedCount,
    required this.allAdded,
    required this.onTap,
    super.key,
  });

  final CatalogSeries series;
  final ProviderType provider;
  final int addedCount;
  final bool allAdded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerAlbums = series.albumsForProvider(provider);
    final String? coverUrl;
    if (series.coverUrl != null) {
      coverUrl = series.coverUrl;
    } else if (providerAlbums.isNotEmpty) {
      coverUrl =
          ref
              .watch(
                albumCoverProvider(
                  '${provider.value}:${providerAlbums.first.id}',
                ),
              )
              .value;
    } else {
      coverUrl = null;
    }
    final total = providerAlbums.length;

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.all(Radius.circular(12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: SizedBox(
                width: 52,
                height: 52,
                child:
                    coverUrl != null
                        ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          memCacheWidth: 104,
                        )
                        : CatalogPlaceholder(title: series.title),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        size: 14,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          series.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Nunito',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    allAdded
                        ? '✓ Alle $total ${series.isMusic ? 'Alben' : 'Folgen'} hinzugefügt'
                        : '$total ${series.isMusic ? 'Alben' : 'Folgen'} · Alles sortiert',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color:
                          allAdded
                              ? AppColors.success
                              : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              allAdded
                  ? Icons.check_circle_rounded
                  : Icons.chevron_right_rounded,
              color: allAdded ? AppColors.success : AppColors.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
