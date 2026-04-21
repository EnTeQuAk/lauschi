import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/catalog/catalog_source.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// A single album result in catalog search results.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({
    required this.album,
    required this.isAdded,
    required this.onAdd,
    required this.onTap,
    super.key,
    this.catalogMatch,
    this.compact = false,
  });

  final CatalogAlbumResult album;
  final bool isAdded;
  final CatalogMatch? catalogMatch;
  final VoidCallback onAdd;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final coverSize = compact ? 44.0 : 56.0;
    final imageSize = compact ? 200 : 400;
    final imageUrl = album.artworkUrlForSize(imageSize);

    final cover = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: SizedBox(
        width: coverSize,
        height: coverSize,
        child:
            imageUrl != null
                ? CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: compact ? 88 : 112,
                  fadeInDuration: const Duration(milliseconds: 200),
                  placeholder:
                      (_, _) => const ColoredBox(
                        color: AppColors.surfaceDim,
                      ),
                  errorWidget:
                      (_, _, _) => const ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: AppColors.textSecondary,
                        ),
                      ),
                )
                : const ColoredBox(
                  color: AppColors.surfaceDim,
                  child: Icon(Icons.music_note_rounded),
                ),
      ),
    );

    // Already-added cards can still be tapped to reassign to current group.
    final trailing = IconButton(
      onPressed: onAdd,
      tooltip: isAdded ? 'Erneut zuweisen' : 'Hinzufügen',
      icon: Icon(isAdded ? Icons.check_rounded : Icons.add_rounded),
      color: isAdded ? AppColors.success : AppColors.primary,
    );

    // Compact mode: hide catalog match chip (the divider already explains it)
    final showCatalogChip = catalogMatch != null && !compact;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: compact ? 4 : 8,
        ),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    album.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontWeight: compact ? FontWeight.w500 : FontWeight.w600,
                      fontSize: compact ? 14 : 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${album.artistName} · ${album.totalTracks} Titel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (showCatalogChip) ...[
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.layers_rounded,
                          size: 11,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            catalogMatch!.episodeNumber != null
                                ? '${catalogMatch!.series.title} · '
                                    'Folge ${catalogMatch!.episodeNumber}'
                                : catalogMatch!.series.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Nunito',
                              fontSize: 11,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}
