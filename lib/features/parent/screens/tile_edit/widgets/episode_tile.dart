import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/ui/undo_snackbar.dart';

/// Whether the item is confirmed unavailable (runtime flag, not endDate).
bool _isUnavailable(db.TileItem card) => card.markedUnavailable != null;

const _tag = 'EpisodeTile';

/// Single episode row in the tile edit reorder list.
class EpisodeTile extends ConsumerWidget {
  const EpisodeTile({
    required this.card,
    required this.index,
    required this.tileId,
    super.key,
  });

  final db.TileItem card;
  final int index;
  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unavailable = _isUnavailable(card);

    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: Opacity(
        opacity: unavailable ? 0.4 : 1.0,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          child: SizedBox(
            width: 40,
            height: 40,
            child:
                card.coverUrl != null
                    ? CachedNetworkImage(
                      imageUrl: card.coverUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: 80,
                      memCacheHeight: 80,
                      fadeInDuration: Duration.zero,
                      placeholder:
                          (_, _) => const ColoredBox(
                            color: AppColors.surfaceDim,
                          ),
                    )
                    : const ColoredBox(
                      color: AppColors.surfaceDim,
                      child: Icon(Icons.music_note_rounded, size: 20),
                    ),
          ),
        ),
      ),
      title: Text(
        card.customTitle ?? card.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: unavailable ? AppColors.textSecondary : null,
        ),
      ),
      subtitle: _buildSubtitle(unavailable: unavailable),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unavailable)
            IconButton(
              icon: const Icon(
                Icons.info_outline_rounded,
                color: AppColors.warning,
                size: 20,
              ),
              tooltip: 'Nicht verfügbar',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showUnavailableInfo(context),
            ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.textSecondary,
            ),
            onSelected: (action) {
              switch (action) {
                case 'remove':
                  unawaited(_removeFromGroup(ref));
                case 'delete':
                  unawaited(_deleteCard(ref));
              }
            },
            itemBuilder:
                (_) => const [
                  PopupMenuItem(
                    value: 'remove',
                    child: Text('Aus Kachel entfernen'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Eintrag löschen',
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Icon(
              Icons.drag_handle_rounded,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildSubtitle({bool unavailable = false}) {
    final parts = <String>[];

    if (unavailable) {
      parts.add('Nicht verfügbar');
    }
    if (card.episodeNumber != null) {
      parts.add('Folge ${card.episodeNumber}');
    }
    if (card.isHeard && !unavailable) {
      parts.add('✓ gehört');
    }

    if (parts.isEmpty) return null;

    // Use appropriate color based on status
    final color =
        unavailable
            ? AppColors.warning
            : parts.contains('✓ gehört')
            ? AppColors.success
            : AppColors.textSecondary;

    return Text(
      parts.join(' · '),
      style: TextStyle(
        fontFamily: 'Nunito',
        fontSize: 12,
        color: color,
        height: 1.2,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  void _showUnavailableInfo(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Nicht verfügbar'),
              content: const Text(
                'Diese Folge ist bei der ARD nicht mehr verfügbar. '
                'Manchmal werden Inhalte später wieder freigeschaltet. '
                'lauschi prüft regelmäßig, ob die Folge zurückkehrt.',
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Verstanden'),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _removeFromGroup(WidgetRef ref) async {
    final tileRepo = ref.read(tileRepositoryProvider);
    final TileSnapshot undo;
    try {
      undo = await ref.read(tileItemRepositoryProvider).removeFromTile(card.id);
      Log.info(
        _tag,
        'Card removed from tile',
        data: {'cardId': card.id, 'tileId': tileId},
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Remove from tile failed', exception: e);
      showAppSnackBar('Entfernen fehlgeschlagen');
      return;
    }
    showUndoSnackBar(
      'Aus Kachel entfernt',
      onUndo: () => unawaited(tileRepo.restore(undo)),
    );
  }

  Future<void> _deleteCard(WidgetRef ref) async {
    final tileRepo = ref.read(tileRepositoryProvider);
    final TileSnapshot undo;
    try {
      undo = await ref.read(tileItemRepositoryProvider).delete(card.id);
      Log.info(_tag, 'Card deleted', data: {'cardId': card.id});
    } on Exception catch (e) {
      Log.error(_tag, 'Delete card failed', exception: e);
      showAppSnackBar('Löschen fehlgeschlagen');
      return;
    }
    showUndoSnackBar(
      'Eintrag gelöscht',
      onUndo: () => unawaited(tileRepo.restore(undo)),
    );
  }
}
