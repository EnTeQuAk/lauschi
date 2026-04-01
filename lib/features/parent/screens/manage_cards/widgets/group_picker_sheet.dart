import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

/// Bottom sheet for assigning a card to a tile group.
class GroupPickerSheet extends ConsumerWidget {
  const GroupPickerSheet({required this.card, super.key});

  final db.TileItem card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allTilesProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              0,
              AppSpacing.screenH,
              AppSpacing.md,
            ),
            child: Text(
              'Kachel zuweisen',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (card.groupId != null)
            ListTile(
              leading: const Icon(
                Icons.cancel_outlined,
                color: AppColors.textSecondary,
              ),
              title: const Text(
                'Aus Kachel entfernen',
                style: TextStyle(fontFamily: 'Nunito'),
              ),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(
                  ref.read(tileItemRepositoryProvider).removeFromTile(card.id),
                );
              },
            ),
          groupsAsync.when(
            data:
                (groups) =>
                    groups.isEmpty
                        ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.screenH,
                            AppSpacing.sm,
                            AppSpacing.screenH,
                            AppSpacing.lg,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Noch keine Kacheln vorhanden.',
                                style: TextStyle(
                                  fontFamily: 'Nunito',
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.md),
                              FilledButton.icon(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  unawaited(
                                    context.push(AppRoutes.parentManageTiles),
                                  );
                                },
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Kachel erstellen'),
                              ),
                            ],
                          ),
                        )
                        : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: groups.length,
                                itemBuilder: (context, index) {
                                  final group = groups[index];
                                  final isAssigned = card.groupId == group.id;
                                  return ListTile(
                                    leading: Icon(
                                      Icons.layers_rounded,
                                      color:
                                          isAssigned
                                              ? AppColors.primary
                                              : AppColors.textSecondary,
                                    ),
                                    title: Text(
                                      group.title,
                                      style: const TextStyle(
                                        fontFamily: 'Nunito',
                                      ),
                                    ),
                                    trailing:
                                        isAssigned
                                            ? const Icon(
                                              Icons.check_rounded,
                                              color: AppColors.primary,
                                            )
                                            : null,
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      unawaited(
                                        ref
                                            .read(tileItemRepositoryProvider)
                                            .assignToTile(
                                              itemId: card.id,
                                              tileId: group.id,
                                            ),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(
                                Icons.add_rounded,
                                color: AppColors.primary,
                              ),
                              title: const Text(
                                'Neue Kachel erstellen',
                                style: TextStyle(
                                  fontFamily: 'Nunito',
                                  color: AppColors.primary,
                                ),
                              ),
                              onTap: () => _createAndAssign(context, ref, card),
                            ),
                          ],
                        ),
            loading:
                () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: CircularProgressIndicator(),
                ),
            error:
                (_, _) => Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Fehler beim Laden der Kacheln.',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      TextButton(
                        onPressed: () => ref.invalidate(allTilesProvider),
                        child: const Text('Erneut versuchen'),
                      ),
                    ],
                  ),
                ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

void _createAndAssign(
  BuildContext context,
  WidgetRef ref,
  db.TileItem card,
) {
  final controller = TextEditingController();
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Neue Kachel'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Name der Serie',
              ),
              onSubmitted: (_) async {
                final title = controller.text.trim();
                if (title.isEmpty) return;
                Navigator.of(ctx).pop();
                Navigator.of(context).pop(); // close bottom sheet
                final groupId = await ref
                    .read(tileRepositoryProvider)
                    .insert(title: title);
                await ref
                    .read(tileItemRepositoryProvider)
                    .assignToTile(itemId: card.id, tileId: groupId);
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () async {
                  final title = controller.text.trim();
                  if (title.isEmpty) return;
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pop(); // close bottom sheet
                  final groupId = await ref
                      .read(tileRepositoryProvider)
                      .insert(title: title);
                  await ref
                      .read(tileItemRepositoryProvider)
                      .assignToTile(itemId: card.id, tileId: groupId);
                },
                child: const Text('Erstellen'),
              ),
            ],
          ),
    ),
  );
}
