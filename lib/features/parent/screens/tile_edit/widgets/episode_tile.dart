import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';

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
        maxLines: 1,
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
                  _removeFromGroup(context, ref);
                case 'delete':
                  _deleteCard(context, ref);
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
    final spans = <InlineSpan>[];

    if (unavailable) {
      spans.add(
        const TextSpan(
          text: 'Nicht verfügbar',
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            color: AppColors.warning,
          ),
        ),
      );
    }

    if (card.episodeNumber != null) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ·  '));
      spans.add(
        TextSpan(
          text: 'Folge ${card.episodeNumber}',
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }

    if (card.isHeard && !unavailable) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ·  '));
      spans.add(
        const TextSpan(
          text: '✓ gehört',
          style: TextStyle(
            fontFamily: 'Nunito',
            fontSize: 12,
            color: AppColors.success,
          ),
        ),
      );
    }

    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans));
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

  void _removeFromGroup(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Aus Kachel entfernen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird aus der Kachel entfernt '
                '(nicht gelöscht).',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Log.info(
                      _tag,
                      'Card removed from tile',
                      data: {
                        'cardId': card.id,
                        'tileId': tileId,
                      },
                    );
                    unawaited(
                      ref
                          .read(tileItemRepositoryProvider)
                          .removeFromTile(card.id),
                    );
                  },
                  child: const Text('Entfernen'),
                ),
              ],
            ),
      ),
    );
  }

  void _deleteCard(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Eintrag löschen?'),
              content: Text(
                '„${card.customTitle ?? card.title}" wird endgültig gelöscht.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Log.info(_tag, 'Card deleted', data: {'cardId': card.id});
                    unawaited(
                      ref.read(tileItemRepositoryProvider).delete(card.id),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Löschen'),
                ),
              ],
            ),
      ),
    );
  }
}
