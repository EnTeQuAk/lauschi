import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';

/// Compact list tile for an individual card in the manage cards screen.
class CardTile extends ConsumerWidget {
  const CardTile({
    required this.card,
    super.key,
    this.showGroupAssign = false,
    this.onAssignGroup,
    this.onDelete,
  });

  final db.TileItem card;

  /// Show group-assign action (for ungrouped cards).
  final bool showGroupAssign;

  /// Called when the user taps the assign-group button.
  final VoidCallback? onAssignGroup;

  /// Called when the user taps the delete button.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHeard = card.isHeard;

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
      ),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: SizedBox(
          width: 40,
          height: 40,
          child:
              card.coverUrl != null
                  ? Opacity(
                    opacity: isHeard ? 0.5 : 1.0,
                    child: CachedNetworkImage(
                      imageUrl: card.coverUrl!,
                      fit: BoxFit.cover,
                    ),
                  )
                  : ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 18,
                      color:
                          isHeard
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                    ),
                  ),
        ),
      ),
      title: Text(
        card.customTitle ?? card.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: isHeard ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      subtitle: _buildSubtitle(card),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card.provider != ProviderType.spotify.value)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ProviderBadge(
                provider: ProviderType.fromString(card.provider),
              ),
            ),
          if (isHeard)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: AppColors.success,
              ),
            ),
          if (showGroupAssign)
            IconButton(
              onPressed: onAssignGroup,
              icon: const Icon(Icons.layers_rounded, size: 20),
              color: AppColors.primary,
              tooltip: 'Kachel zuweisen',
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: AppColors.error,
            tooltip: 'Entfernen',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

Widget? _buildSubtitle(db.TileItem card) {
  if (card.episodeNumber == null) return null;
  return Text(
    'Folge ${card.episodeNumber}',
    style: const TextStyle(
      fontFamily: 'Nunito',
      fontSize: 12,
      color: AppColors.textSecondary,
    ),
  );
}
