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
import 'package:lauschi/core/ui/undo_snackbar.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/cover_picker.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/episode_reorder_list.dart';

const _tag = 'TileEditScreen';

/// Parent edit screen for a single series group.
///
/// Title / cover are editable; episodes are shown in order and can be
/// reordered or removed. Cards are assigned from the series manager.
class TileEditScreen extends ConsumerStatefulWidget {
  const TileEditScreen({required this.tileId, super.key});

  final String tileId;

  @override
  ConsumerState<TileEditScreen> createState() => _TileEditScreenState();
}

class _TileEditScreenState extends ConsumerState<TileEditScreen> {
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

  Future<void> _deleteAllCards() async {
    Log.info(_tag, 'Deleting all cards', data: {'tileId': widget.tileId});
    final tileRepo = ref.read(tileRepositoryProvider);
    final TileSnapshot undo;
    try {
      undo = await ref
          .read(tileItemRepositoryProvider)
          .deleteByTile(widget.tileId);
    } on Exception catch (e) {
      Log.error(_tag, 'Delete all cards failed', exception: e);
      showAppSnackBar('Löschen fehlgeschlagen');
      return;
    }
    final count = undo.items.length;
    showUndoSnackBar(
      '$count ${count == 1 ? 'Eintrag' : 'Einträge'} gelöscht',
      onUndo: () => unawaited(tileRepo.restore(undo)),
    );
  }

  Future<void> _deleteGroup(BuildContext context) async {
    Log.info(_tag, 'Deleting tile', data: {'tileId': widget.tileId});
    final tileRepo = ref.read(tileRepositoryProvider);
    final TileSnapshot undo;
    try {
      undo = await tileRepo.delete(widget.tileId);
    } on Exception catch (e) {
      Log.error(_tag, 'Delete tile failed', exception: e);
      showAppSnackBar('Löschen fehlgeschlagen');
      return;
    }
    showUndoSnackBar(
      'Kachel gelöscht',
      onUndo: () => unawaited(tileRepo.restore(undo)),
    );
    if (context.mounted) {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.parentManageTiles);
      }
    }
  }

  void _showSaveError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Speichern fehlgeschlagen'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Bitte einen Namen eingeben'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    Log.info(
      _tag,
      'Saving tile',
      data: {'tileId': widget.tileId, 'title': title},
    );
    final cover = _coverController.text.trim();
    try {
      await ref
          .read(tileRepositoryProvider)
          .update(
            id: widget.tileId,
            title: title,
            coverUrl: cover.isEmpty ? null : cover,
            clearCoverUrl: cover.isEmpty,
          );
    } on Exception catch (e) {
      Log.error(_tag, 'Save tile failed', exception: e);
      _showSaveError();
      return;
    }
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

  /// Persists just the cover, bypassing the required-title validation in
  /// [_save]. Picking or clearing a cover auto-saves; it must not be
  /// dropped (or surface a name error) when the title field happens to be
  /// empty, since the two edits are independent.
  Future<void> _saveCover() async {
    final cover = _coverController.text.trim();
    try {
      await ref
          .read(tileRepositoryProvider)
          .update(
            id: widget.tileId,
            coverUrl: cover.isEmpty ? null : cover,
            clearCoverUrl: cover.isEmpty,
          );
    } on Exception catch (e) {
      Log.error(_tag, 'Save cover failed', exception: e);
      _showSaveError();
      return;
    }
    // The cover is saved. Clear the dirty flag only when the title field
    // still matches what's stored, so a pending (unsaved) title edit keeps
    // the Save button around.
    if (!mounted) return;
    final persistedTitle =
        ref.read(tileByIdProvider(widget.tileId)).value?.title;
    if (_titleController.text.trim() == persistedTitle) {
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
        if (!_initialized) {
          // Schedule controller initialization after the current frame
          // to avoid mutating state during build (AGENTS.md quality bar).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_initialized) {
              _titleController.text = group.title;
              _coverController.text = group.coverUrl ?? '';
              _initialized = true;
            }
          });
        }
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
        title: const Text(
          'Kachel bearbeiten',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18),
        ),
        actions: [
          if (_dirty)
            TextButton(
              key: const Key('save_tile'),
              onPressed: _save,
              child: const Text('Speichern'),
            ),
          PopupMenuButton<String>(
            key: const Key('tile_edit_menu'),
            onSelected: (action) {
              switch (action) {
                case 'delete_cards':
                  unawaited(_deleteAllCards());
                case 'delete_group':
                  unawaited(_deleteGroup(context));
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
                  key: const Key('tile_title_field'),
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
                  onAutoSave: _saveCover,
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
                const Text(
                  'Folgen',
                  style: TextStyle(
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
