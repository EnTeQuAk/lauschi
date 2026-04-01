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
    this.showImageUrl,
  });

  final ArdItem item;
  final bool alreadyAdded;
  final bool isAdding;
  final bool enabled;
  final VoidCallback onAdd;

  /// Fallback image when the episode has no unique artwork.
  final String? showImageUrl;

  @override
  Widget build(BuildContext context) {
    final episodeImageUrl = ardImageUrl(item.imageUrl, width: 112);
    final fallbackUrl = ardImageUrl(showImageUrl, width: 112);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: 2,
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
              alreadyAdded
                  ? const Icon(Icons.check_circle, color: AppColors.success)
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
          color: alreadyAdded ? AppColors.textSecondary : AppColors.textPrimary,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Text(
            formatDuration(item.duration),
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          if (item.group != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Teil ${item.episodeNumber ?? "?"}/${item.group!.count ?? "?"}',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
      enabled: enabled && !alreadyAdded && !isAdding,
      onTap: enabled && !alreadyAdded && !isAdding ? onAdd : null,
    );
  }
}
