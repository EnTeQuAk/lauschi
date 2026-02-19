import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/screens/group_detail_screen.dart';

/// Parent edit screen for a single series group.
///
/// Title / cover are editable; episodes are shown in order and can be
/// reordered or removed. Cards are assigned from ManageCardsScreen.
class GroupEditScreen extends ConsumerStatefulWidget {
  const GroupEditScreen({required this.groupId, super.key});

  final String groupId;

  @override
  ConsumerState<GroupEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends ConsumerState<GroupEditScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _coverController;
  bool _dirty = false;

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

  void _onLoaded(db.CardGroup group) {
    if (_dirty) return; // User already started editing
    _titleController.text = group.title;
    _coverController.text = group.coverUrl ?? '';
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) return;
    await ref.read(groupRepositoryProvider).update(
          id: widget.groupId,
          title: title,
          coverUrl: _coverController.text.trim().isEmpty
              ? null
              : _coverController.text.trim(),
          clearCoverUrl: _coverController.text.trim().isEmpty,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Serie gespeichert'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() => _dirty = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupAsync = ref.watch(groupByIdProvider(widget.groupId));
    final episodesAsync = ref.watch(groupEpisodesProvider(widget.groupId));

    return groupAsync.when(
      data: (group) {
        if (group == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Serie')),
            body: const Center(child: Text('Serie nicht gefunden')),
          );
        }
        _onLoaded(group);
        return _buildScaffold(context, group, episodesAsync);
      },
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Serie')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => Scaffold(
        appBar: AppBar(title: const Text('Serie')),
        body: const Center(child: Text('Fehler beim Laden')),
      ),
    );
  }

  Widget _buildScaffold(
    BuildContext context,
    db.CardGroup group,
    AsyncValue<List<db.AudioCard>> episodesAsync,
  ) {
    final episodes = episodesAsync.value ?? <db.AudioCard>[];
    final episodeCovers = episodes
        .map((e) => e.coverUrl)
        .whereType<String>()
        .toSet()
        .toList();

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Serie bearbeiten'),
        actions: [
          if (_dirty)
            TextButton(
              onPressed: _save,
              child: const Text('Speichern'),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(
          context.push(AppRoutes.parentAddCardToGroup(widget.groupId)),
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
                    labelText: 'Serientitel',
                  ),
                  onChanged: (_) => setState(() => _dirty = true),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: AppSpacing.md),
                _CoverPicker(
                  controller: _coverController,
                  episodeCovers: episodeCovers,
                  onChanged: () => setState(() => _dirty = true),
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
              data: (eps) => eps.isEmpty
                  ? const _EmptyEpisodesHint()
                  : _EpisodeReorderList(
                      groupId: widget.groupId,
                      episodes: eps,
                    ),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (_, _) => const Center(
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
// Cover picker: shows current cover, episode cover chips, and a URL fallback.
// ---------------------------------------------------------------------------

class _CoverPicker extends StatefulWidget {
  const _CoverPicker({
    required this.controller,
    required this.episodeCovers,
    required this.onChanged,
  });

  final TextEditingController controller;

  /// Distinct cover URLs already present in the group's episodes.
  final List<String> episodeCovers;

  final VoidCallback onChanged;

  @override
  State<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends State<_CoverPicker> {
  String get _currentUrl => widget.controller.text.trim();

  void _pickCover(String url) {
    widget.controller.text = url;
    widget.onChanged();
  }

  void _clearCover() {
    widget.controller.clear();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Cover preview
            ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.card),
              child: SizedBox(
                width: 72,
                height: 72,
                child: _currentUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _currentUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const _CoverPlaceholder(),
                      )
                    : const _CoverPlaceholder(),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Serien-Cover',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _currentUrl.isNotEmpty
                        ? 'Tippe auf eine Folge unten zum Ändern'
                        : 'Wähle das Cover einer Folge',
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (_currentUrl.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _clearCover,
                      child: const Text(
                        'Entfernen',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 12,
                          color: AppColors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),

        // Episode cover chips
        if (widget.episodeCovers.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Von Folgen übernehmen',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: widget.episodeCovers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final url = widget.episodeCovers[index];
                final isSelected = _currentUrl == url;
                return GestureDetector(
                  onTap: () => _pickCover(url),
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.all(AppRadius.card),
                      border: isSelected
                          ? Border.all(color: AppColors.primary, width: 2.5)
                          : null,
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(AppRadius.card),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceDim,
      child: Icon(
        Icons.layers_rounded,
        size: 32,
        color: AppColors.textSecondary,
      ),
    );
  }
}

class _EpisodeReorderList extends ConsumerWidget {
  const _EpisodeReorderList({
    required this.groupId,
    required this.episodes,
  });

  final String groupId;
  final List<db.AudioCard> episodes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
        final reordered = List<db.AudioCard>.from(episodes);
        final item = reordered.removeAt(oldIndex);
        reordered.insert(insertAt, item);
        unawaited(
          ref.read(cardRepositoryProvider).reorder(
            reordered.map((c) => c.id).toList(),
          ),
        );
      },
      itemCount: episodes.length,
      itemBuilder: (context, index) {
        final card = episodes[index];
        return _EpisodeTile(
          key: ValueKey(card.id),
          card: card,
          index: index,
          groupId: groupId,
        );
      },
    );
  }
}

class _EpisodeTile extends ConsumerWidget {
  const _EpisodeTile({
    required this.card,
    required this.index,
    required this.groupId,
    super.key,
  });

  final db.AudioCard card;
  final int index;
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      tileColor: AppColors.parentSurface,
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        child: SizedBox(
          width: 40,
          height: 40,
          child: card.coverUrl != null
              ? CachedNetworkImage(
                  imageUrl: card.coverUrl!,
                  fit: BoxFit.cover,
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
      subtitle: card.isHeard
          ? const Text(
              '✓ gehört',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                color: AppColors.success,
              ),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _removeFromGroup(context, ref),
            icon: const Icon(Icons.remove_circle_outline_rounded),
            color: AppColors.textSecondary,
            tooltip: 'Aus Serie entfernen',
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Icon(Icons.drag_handle_rounded,
                color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  void _removeFromGroup(BuildContext context, WidgetRef ref) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Aus Serie entfernen?'),
          content: Text(
            '„${card.customTitle ?? card.title}" wird aus der Serie entfernt '
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
                unawaited(
                  ref
                      .read(cardRepositoryProvider)
                      .removeFromGroup(card.id),
                );
              },
              child: const Text('Entfernen'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyEpisodesHint extends StatelessWidget {
  const _EmptyEpisodesHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.playlist_add_rounded,
                size: 40, color: AppColors.textSecondary),
            SizedBox(height: AppSpacing.md),
            Text(
              'Noch keine Folgen in dieser Serie.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                color: AppColors.textSecondary,
              ),
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              'Gehe zu „Karten verwalten", um Karten dieser Serie zuzuweisen.',
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
