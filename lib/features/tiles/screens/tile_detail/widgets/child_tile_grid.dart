import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/catalog/catalog_service.dart' show ContentType;
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/card_indicator.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// Grid of child tiles inside a parent tile.
class ChildTileGrid extends ConsumerWidget {
  const ChildTileGrid({
    required this.children,
    required this.onTileTap,
    super.key,
  });

  final List<db.Tile> children;
  final void Function(db.Tile) onTileTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressMap = ref.watch(tileProgressProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = kidGridColumns(constraints.maxWidth);

        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: children.length,
          itemBuilder: (context, index) {
            final child = children[index];
            final indicator = tileIndicator(progressMap[child.id]);
            final childCovers =
                ref
                    .watch(childTilesProvider(child.id))
                    .whenOrNull(
                      data:
                          (tiles) =>
                              tiles
                                  .where((t) => t.coverUrl != null)
                                  .take(4)
                                  .map((t) => t.coverUrl!)
                                  .toList(),
                    ) ??
                const <String>[];

            return TileCard(
              key: Key('child_tile_${child.id}'),
              title: child.title,
              episodeCount: indicator.episodeCount,
              coverUrl: child.coverUrl,
              progress: indicator.progress,
              contentType: ContentType.fromString(child.contentType),
              childCoverUrls: childCovers,
              kidMode: true,
              isUnavailable: indicator.isUnavailable,
              onTap: () => onTileTap(child),
            );
          },
        );
      },
    );
  }
}
