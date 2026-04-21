import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lauschi/core/ard/ard_helpers.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Single episode row in the ARD show detail screen.
class ArdEpisodeTile extends StatelessWidget {
  const ArdEpisodeTile({
    required this.item,
    required this.alreadyAdded,
    required this.isAdding,
    required this.enabled,
    required this.onAdd,
    super.key,
    this.onRemove,
    this.isRemoving = false,
    this.showImageUrl,
    this.isFeatured = false,
  });

  final ArdItem item;
  final bool alreadyAdded;
  final bool isAdding;
  final bool isRemoving;
  final bool enabled;
  final VoidCallback onAdd;

  /// Called when the user wants to remove an already-added episode.
  final VoidCallback? onRemove;

  /// Fallback image when the episode has no unique artwork.
  final String? showImageUrl;

  /// Whether this episode is featured (shown at top from navigation).
  final bool isFeatured;

  @override
  Widget build(BuildContext context) {
    final episodeImageUrl = ardImageUrl(item.imageUrl, width: 112);
    final fallbackUrl = ardImageUrl(showImageUrl, width: 112);

    return Container(
      decoration:
          isFeatured
              ? BoxDecoration(
                color: AppColors.accent.withAlpha(15),
                border: const Border(
                  left: BorderSide(
                    color: AppColors.accent,
                    width: 3,
                  ),
                ),
              )
              : null,
      child: ListTile(
        contentPadding: EdgeInsets.only(
          left: isFeatured ? AppSpacing.screenH - 3 : AppSpacing.screenH,
          right: AppSpacing.screenH,
          top: 2,
          bottom: 2,
        ),
        leading: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: SizedBox(
            width: 56,
            height: 56,
            child: CachedNetworkImage(
              imageUrl: episodeImageUrl ?? fallbackUrl ?? '',
              fit: BoxFit.cover,
              placeholder:
                  (_, _) => ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Center(
                      child: Text(
                        item.episodeNumber?.toString() ?? '',
                        style: const TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              errorWidget:
                  (_, _, _) => const ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Center(
                      child: Icon(
                        Icons.headphones_rounded,
                        size: 20,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
            ),
          ),
        ),
        trailing: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child:
                isRemoving
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : alreadyAdded
                    ? IconButton(
                      icon: const Icon(
                        Icons.check_circle,
                        color: AppColors.success,
                      ),
                      onPressed: onRemove,
                      tooltip: 'Entfernen',
                      padding: EdgeInsets.zero,
                    )
                    : isAdding
                    ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : IconButton(
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      onPressed: enabled ? onAdd : null,
                      padding: EdgeInsets.zero,
                    ),
          ),
        ),
        title: Text(
          item.displayTitle,
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 14,
            color:
                alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
            fontWeight: isFeatured ? FontWeight.w600 : FontWeight.normal,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          _buildSubtitle(item),
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            color: AppColors.textSecondary,
            height: 1.2,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        enabled: enabled && !isAdding && !isRemoving,
        onTap: alreadyAdded ? onRemove : (enabled && !isAdding ? onAdd : null),
      ),
    );
  }

  String _buildSubtitle(ArdItem item) {
    final parts = <String>[formatDuration(item.duration)];
    if (item.group != null) {
      parts.add(
        'Teil ${item.episodeNumber ?? "?"}/${item.group!.count ?? "?"}',
      );
    }
    return parts.join(' · ');
  }
}
