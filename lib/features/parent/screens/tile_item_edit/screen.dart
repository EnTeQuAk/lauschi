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
import 'package:lauschi/features/parent/widgets/group_picker_sheet.dart';

const _tag = 'TileItemEditScreen';

/// The customTitle override to persist for the edited [fieldText] given
/// the item's canonical [originalTitle]. Returns null (clear the override)
/// when the field is empty or merely echoes the original title, so a
/// save that only changed the cover can't silently promote the original
/// name into a stored override that would then mask later upstream title
/// changes.
@visibleForTesting
String? resolveCustomTitle(String fieldText, String originalTitle) {
  final trimmed = fieldText.trim();
  if (trimmed.isEmpty || trimmed == originalTitle) return null;
  return trimmed;
}

/// Parent edit screen for a single ungrouped (or grouped) item.
///
/// Mirrors the tile-edit screen's shape: title + cover meta block at
/// the top, action area below. An item doesn't own a list of children
/// (it IS the leaf), so the body has actions instead of an episode
/// list: assign to a tile, delete.
class TileItemEditScreen extends ConsumerStatefulWidget {
  const TileItemEditScreen({required this.itemId, super.key});

  final String itemId;

  @override
  ConsumerState<TileItemEditScreen> createState() => _TileItemEditScreenState();
}

class _TileItemEditScreenState extends ConsumerState<TileItemEditScreen> {
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

  Future<void> _save() async {
    final originalTitle =
        ref.read(tileItemByIdProvider(widget.itemId)).value?.title ?? '';
    final customTitle = resolveCustomTitle(
      _titleController.text,
      originalTitle,
    );
    final cover = _coverController.text.trim();
    Log.info(
      _tag,
      'Saving item',
      data: {'itemId': widget.itemId, 'override': '${customTitle != null}'},
    );
    try {
      await ref
          .read(tileItemRepositoryProvider)
          .updateMeta(
            id: widget.itemId,
            customTitle: customTitle,
            clearCustomTitle: customTitle == null,
            coverUrl: cover.isEmpty ? null : cover,
            clearCoverUrl: cover.isEmpty,
          );
    } on Exception catch (e) {
      Log.error(_tag, 'Save item failed', exception: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Speichern fehlgeschlagen'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('Folge gespeichert'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      setState(() => _dirty = false);
    }
  }

  Future<void> _deleteItem(BuildContext context) async {
    Log.info(_tag, 'Deleting item', data: {'itemId': widget.itemId});
    final tileRepo = ref.read(tileRepositoryProvider);
    final TileSnapshot undo;
    try {
      undo = await ref.read(tileItemRepositoryProvider).delete(widget.itemId);
    } on Exception catch (e) {
      Log.error(_tag, 'Delete item failed', exception: e);
      showAppSnackBar('Löschen fehlgeschlagen');
      return;
    }
    if (undo.isEmpty) return; // Already gone; nothing to undo.
    showUndoSnackBar(
      'Folge gelöscht',
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

  @override
  Widget build(BuildContext context) {
    final itemAsync = ref.watch(tileItemByIdProvider(widget.itemId));

    return itemAsync.when(
      data: (item) {
        if (item == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Folge')),
            body: const Center(child: Text('Folge nicht gefunden')),
          );
        }
        if (!_initialized) {
          // Match tile_edit: defer controller writes off the build pass.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_initialized) {
              _titleController.text = item.customTitle ?? item.title;
              _coverController.text = item.coverUrl ?? '';
              _initialized = true;
            }
          });
        }
        return _buildScaffold(context, item);
      },
      loading:
          () => Scaffold(
            appBar: AppBar(title: const Text('Folge')),
            body: const Center(child: CircularProgressIndicator()),
          ),
      error:
          (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Folge')),
            body: const Center(child: Text('Fehler beim Laden')),
          ),
    );
  }

  Widget _buildScaffold(BuildContext context, db.TileItem item) {
    // The item is its own cover. CoverPicker also wants suggestion
    // rails; we feed it the item's own URL plus any Spotify artist
    // IDs the catalog import recorded so the parent can switch to an
    // artist portrait without leaving the screen.
    final episodeCovers = [item.coverUrl].whereType<String>().toSet().toList();
    final artistIds =
        (item.spotifyArtistIds ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text(
          'Folge bearbeiten',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 18),
        ),
        actions: [
          if (_dirty)
            TextButton(
              key: const Key('save_tile_item'),
              onPressed: _save,
              child: const Text('Speichern'),
            ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'delete':
                  unawaited(_deleteItem(context));
              }
            },
            itemBuilder:
                (_) => [
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Folge löschen'),
                  ),
                ],
          ),
        ],
      ),
      body: ListView(
        children: [
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
                  key: const Key('tile_item_title_field'),
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: 'Name der Folge',
                    hintText: item.title,
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
          const SizedBox(height: AppSpacing.md),
          ListTile(
            key: const Key('assign_to_tile'),
            leading: const Icon(
              Icons.layers_rounded,
              color: AppColors.textSecondary,
            ),
            title: const Text(
              'In Kachel verschieben…',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            subtitle:
                item.groupId != null
                    ? const Text(
                      'Aktuell einer Kachel zugeordnet',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    )
                    : null,
            trailing: const Icon(Icons.chevron_right_rounded),
            tileColor: AppColors.parentSurface,
            onTap: () => _showGroupPicker(context, item),
          ),
        ],
      ),
    );
  }

  void _showGroupPicker(BuildContext context, db.TileItem item) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => GroupPickerSheet(card: item),
      ),
    );
  }
}
