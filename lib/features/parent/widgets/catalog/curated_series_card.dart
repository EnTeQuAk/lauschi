import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/catalog/catalog_helpers.dart';

/// Grid card for a curated series in the catalog browse view.
class CuratedSeriesCard extends ConsumerWidget {
  const CuratedSeriesCard({
    required this.series,
    required this.provider,
    super.key,
    this.autoAssignTileId,
    this.onSearchSeries,
  });

  final CatalogSeries series;
  final ProviderType provider;
  final String? autoAssignTileId;

  /// Called when tapping a series on a non-Spotify provider.
  /// Triggers a search for the series title in the browse screen.
  final ValueChanged<String>? onSearchSeries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final existingUris = ref.watch(existingItemUrisProvider);
    final providerAlbums = series.albumsForProvider(provider);

    // Curated cover_url from YAML takes priority. Per-card cover fetch
    // is the fallback: each card independently resolves its first album's
    // artwork URL so covers appear progressively.
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
    final added =
        providerAlbums.where((a) => existingUris.contains(a.uri)).length;
    final allAdded = added == total && total > 0;

    return GestureDetector(
      onTap: () {
        if (allAdded) {
          final groups = ref.read(allTilesProvider).value ?? [];
          final matchingGroup = groups.where(
            (g) => g.title.toLowerCase() == series.title.toLowerCase(),
          );
          if (matchingGroup.isNotEmpty) {
            unawaited(
              context.push(
                AppRoutes.parentTileEdit(matchingGroup.first.id),
              ),
            );
            return;
          }
        }
        if (series.hasCuratedAlbumsFor(provider)) {
          unawaited(
            context.push(
              '${AppRoutes.parentCatalogSeries(series.id)}'
              '?provider=${provider.value}',
              extra: autoAssignTileId,
            ),
          );
        } else {
          onSearchSeries?.call(series.title);
        }
      },
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(AppRadius.card),
                    child:
                        coverUrl != null
                            ? CachedNetworkImage(
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              placeholder:
                                  (_, _) =>
                                      CatalogPlaceholder(title: series.title),
                              errorWidget:
                                  (_, _, _) =>
                                      CatalogPlaceholder(title: series.title),
                            )
                            : CatalogPlaceholder(title: series.title),
                  ),
                ),
                if (added > 0)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: allAdded ? AppColors.success : AppColors.primary,
                        borderRadius: const BorderRadius.all(AppRadius.pill),
                      ),
                      child:
                          allAdded
                              ? const Icon(
                                Icons.check_rounded,
                                size: 12,
                                color: Colors.white,
                              )
                              : Text(
                                '$added/$total',
                                style: const TextStyle(
                                  fontFamily: 'Nunito',
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            series.title,
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
          Text(
            allAdded
                ? '✓ Hinzugefügt'
                : added > 0
                ? '$added von $total ${series.isMusic ? 'Alben' : 'Folgen'}'
                : '$total ${series.isMusic ? 'Alben' : 'Folgen'}',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 10,
              color: allAdded ? AppColors.success : AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
