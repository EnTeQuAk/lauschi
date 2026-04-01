import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/episode_tile.dart';

const _tag = 'EpisodeReorderList';

/// Reorderable list of episodes within a tile edit screen.
class EpisodeReorderList extends ConsumerWidget {
  const EpisodeReorderList({
    required this.tileId,
    required this.episodes,
    super.key,
  });

  final String tileId;
  final List<db.TileItem> episodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.fabClearance),
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder:
              (context, child) => Material(
                elevation: 4,
                shadowColor: Colors.black26,
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: child,
              ),
          child: child,
        );
      },
      onReorder: (oldIndex, newIndex) {
        final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final reordered = List<db.TileItem>.from(episodes);
        final item = reordered.removeAt(oldIndex);
        reordered.insert(insertAt, item);
        Log.info(
          _tag,
          'Episodes reordered',
          data: {
            'tileId': tileId,
            'movedItem': item.id,
            'from': '$oldIndex',
            'to': '$insertAt',
          },
        );
        unawaited(
          ref
              .read(tileItemRepositoryProvider)
              .reorder(
                reordered.map((c) => c.id).toList(),
              ),
        );
      },
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final card = episodes[index];
        return EpisodeTile(
          key: ValueKey(card.id),
          card: card,
          index: index,
          tileId: tileId,
        );
      },
    );
  }
}
