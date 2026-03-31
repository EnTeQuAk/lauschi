import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/cover_picker.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/episode_reorder_list.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/screen.dart';

const _tag = 'TileEditScreen';

/// Parent edit screen for a single series group.
///
/// Title / cover are editable; episodes are shown in order and can be
/// reordered or removed. Cards are assigned from the series manager.
class TileEditScreen extends ConsumerStatefulWidget {
  const TileEditScreen({required this.tileId, super.key});

  final String tileId;

  @override
  ConsumerState<TileEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends ConsumerState<TileEditScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _coverController;
  bool _dirty = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _coverController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  void _onLoaded(db.Tile group) {
    if (_initialized) return;
    _titleController.text = group.title;
    _coverController.text = group.coverUrl ?? '';
    _initialized = true;
  }

  void _confirmDeleteAllCards(BuildContext context) {
    Log.info(
      _tag,
      'Delete all cards dialog shown',
      data: {'tileId': widget.tileId},
    );
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Alle Folgen löschen?'),
              content: const Text(
                'Alle Einträge in dieser Kachel werden unwiderruflich '
                'entfernt. Die Kachel selbst bleibt bestehen.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    final count = await ref
                        .read(tileItemRepositoryProvider)
                        .deleteByTile(widget.tileId);
                    Log.info(
                      _tag,
                      'All cards deleted',
                      data: {'tileId': widget.tileId, 'count': '$count'},
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(
                          SnackBar(
                            content: Text(
                              '$count ${count == 1 ? 'Eintrag' : 'Einträge'} '
                              'entfernt',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Alle löschen'),
                ),
              ],
            ),
      ),
    );
  }

  void _confirmDeleteGroup(BuildContext context) {
    Log.info(
      _tag,
      'Delete tile dialog shown',
      data: {'tileId': widget.tileId},
    );
    unawaited(
      showDialog<void>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('Kachel löschen?'),
              content: const Text(
                'Die Kachel und alle zugehörigen Einträge werden '
                'unwiderruflich entfernt.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await ref
                        .read(tileItemRepositoryProvider)
                        .deleteByTile(widget.tileId);
                    await ref
                        .read(tileRepositoryProvider)
                        .delete(widget.tileId);
                    Log.info(
                      _tag,
                      'Tile deleted',
                      data: {'tileId': widget.tileId},
                    );
                    if (context.mounted) {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.parentManageTiles);
                      }
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                  ),
                  child: const Text('Kachel löschen'),
                ),
              ],
            ),
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    Log.info(
      _tag,
      'Saving tile',
      data: {'tileId': widget.tileId, 'title': title},
    );
    await ref
        .read(tileRepositoryProvider)
        .update(
          id: widget.tileId,
          title: title,
          coverUrl:
              _coverController.text.trim().isEmpty
                  ? null
                  : _coverController.text.trim(),
          clearCoverUrl: _coverController.text.trim().isEmpty,
        );
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Kachel gespeichert'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      setState(() => _dirty = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupAsync = ref.watch(tileByIdProvider(widget.tileId));
    final episodesAsync = ref.watch(tileItemsProvider(widget.tileId));

    return groupAsync.when(
      data: (group) {
        if (group == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: Text('Kachel nicht gefunden')),
          );
        }
        _onLoaded(group);
        return _buildScaffold(context, group, episodesAsync);
      },
      loading:
          () => Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: CircularProgressIndicator()),
          ),
      error:
          (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Kachel')),
            body: const Center(child: Text('Fehler beim Laden')),
          ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    db.Tile group,
    AsyncValue<List<db.TileItem>> episodesAsync,
  ) {
    final episodes = episodesAsync.value ?? <db.TileItem>[];
    final episodeCovers =
        episodes.map((e) => e.coverUrl).whereType<String>().toSet().toList();

    final artistIds =
        episodes
            .map((e) => e.spotifyArtistIds)
            .whereType<String>()
            .expand((ids) => ids.split(','))
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList();

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Kachel bearbeiten'),
        actions: [
          if (_dirty)
            TextButton(
              key: const Key('save_tile'),
              onPressed: _save,
              child: const Text('Speichern'),
            ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'delete_cards':
                  _confirmDeleteAllCards(context);
                case 'delete_group':
                  _confirmDeleteGroup(context);
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(
                    value: 'delete_cards',
                    child: Text('Alle Folgen löschen'),
                  ),
                  const PopupMenuItem(
                    value: 'delete_group',
                    child: Text('Kachel löschen'),
                  ),
                ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_episode_fab'),
        onPressed:
            () => unawaited(
              context.push(AppRoutes.parentAddToTile(widget.tileId)),
            ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Folge hinzufügen'),
      ),
      body: Column(
        children: [
          // Meta fields
          Container(
            color: AppColors.parentSurface,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.md,
              AppSpacing.screenH,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Name der Kachel',
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: AppSpacing.md),
                CoverPicker(
                  controller: _coverController,
                  episodeCovers: episodeCovers,
                  artistIds: artistIds,
                  onChanged: () => setState(() => _dirty = true),
                  onAutoSave: _save,
                ),
              ],
            ),
          ),

          // Episodes header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenH,
              AppSpacing.md,
              AppSpacing.screenH,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  'FOLGEN'.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: AppColors.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  episodes.isEmpty ? '' : '${episodes.length}',
                  style: const TextStyle(
                    fontFamily: 'Nunito',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Episode list
          Expanded(
            child: episodesAsync.when(
              data:
                  (eps) =>
                      eps.isEmpty
                          ? const _EmptyEpisodesHint()
                          : EpisodeReorderList(
                            tileId: widget.tileId,
                            episodes: eps,
                          ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error:
                  (_, _) => const Center(
                    child: Text('Fehler beim Laden der Folgen.'),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty episodes hint (inline, tiny)
// ---------------------------------------------------------------------------

class _EmptyEpisodesHint extends StatelessWidget {
  const _EmptyEpisodesHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_add_rounded,
              size: 32,
              color: AppColors.textSecondary,
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Tippe auf „Folge hinzufügen" um Folgen hinzuzufügen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
