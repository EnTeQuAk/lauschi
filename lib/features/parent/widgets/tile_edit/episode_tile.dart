import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';

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
    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: ClipRRect(
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
      title: Text(
        card.customTitle ?? card.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      subtitle: _buildSubtitle(),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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

  Widget? _buildSubtitle() {
    final spans = <InlineSpan>[];

    if (card.episodeNumber != null) {
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

    if (card.isHeard) {
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
