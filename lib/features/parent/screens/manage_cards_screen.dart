import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/catalog/catalog_service.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/widgets/provider_badge.dart';

const _tag = 'ManageCards';

/// All cards grouped by their series. Ungrouped cards in a separate section.
class ManageCardsScreen extends ConsumerWidget {
  const ManageCardsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);
    final ungroupedAsync = ref.watch(ungroupedCardsProvider);
    final totalCards =
        ref.watch(allCardsProvider).whenOrNull(data: (c) => c.length) ?? 0;

    return Scaffold(
      backgroundColor: AppColors.parentBackground,
      appBar: AppBar(
        backgroundColor: AppColors.parentBackground,
        title: const Text('Karten verwalten'),
        actions: [
          IconButton(
            onPressed: () => context.push(AppRoutes.parentAddCard),
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Hörspiel hinzufügen',
          ),
        ],
      ),
      body:
          totalCards == 0
              ? _EmptyState(onAdd: () => context.push(AppRoutes.parentAddCard))
              : _GroupedCardList(
                groupsAsync: groupsAsync,
                ungroupedAsync: ungroupedAsync,
              ),
    );
  }
}

// ---------------------------------------------------------------------------
// Main list: series sections + ungrouped section
// ---------------------------------------------------------------------------

class _GroupedCardList extends ConsumerStatefulWidget {
  const _GroupedCardList({
    required this.groupsAsync,
    required this.ungroupedAsync,
  });

  final AsyncValue<List<db.CardGroup>> groupsAsync;
  final AsyncValue<List<db.AudioCard>> ungroupedAsync;

  @override
  ConsumerState<_GroupedCardList> createState() => _GroupedCardListState();
}

class _GroupedCardListState extends ConsumerState<_GroupedCardList> {
  final _ungroupedKey = GlobalKey();

  void _scrollToUngrouped() {
    final ctx = _ungroupedKey.currentContext;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.groupsAsync.whenOrNull(data: (g) => g) ?? [];
    final ungrouped = widget.ungroupedAsync.whenOrNull(data: (c) => c) ?? [];

    return CustomScrollView(
      slivers: [
        // Auto-sort banner for ungrouped cards
        if (ungrouped.isNotEmpty)
          SliverToBoxAdapter(
            child: _AutoSortBanner(
              ungroupedCount: ungrouped.length,
              onTap: _scrollToUngrouped,
            ),
          ),

        // Series sections
        for (final group in groups) _GroupSection(group: group),

        // Ungrouped cards at the bottom
        if (ungrouped.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _SectionHeader(
              key: _ungroupedKey,
              title: 'Ohne Serie',
              subtitle: '${ungrouped.length} Karten',
              icon: Icons.layers_clear_rounded,
            ),
          ),
          SliverList.builder(
            itemCount: ungrouped.length,
            itemBuilder:
                (context, index) => _CardTile(
                  card: ungrouped[index],
                  showGroupAssign: true,
                ),
          ),
        ],

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xxl)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Series section: header + episode list
// ---------------------------------------------------------------------------

class _GroupSection extends ConsumerWidget {
  const _GroupSection({required this.group});

  final db.CardGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(_groupCardsProvider(group.id));
    final cardCount = cardsAsync.whenOrNull(data: (c) => c.length) ?? 0;

    final countLabel =
        group.contentType == 'music' ? '$cardCount Titel' : '$cardCount Folgen';

    return SliverToBoxAdapter(
      child: _SectionHeader(
        title: group.title,
        subtitle: countLabel,
        coverUrl: group.coverUrl,
        icon:
            group.contentType == 'music'
                ? Icons.music_note_rounded
                : Icons.auto_stories_rounded,
        onTap: () => context.push(AppRoutes.parentGroupEdit(group.id)),
        onDelete: () => _confirmDeleteGroup(context, ref, group, cardCount),
      ),
    );
  }
}

/// Cards for a group — watches the stream so count stays in sync.
final _groupCardsProvider = StreamProvider.family<List<db.AudioCard>, String>((
  ref,
  groupId,
) {
  return ref.watch(groupRepositoryProvider).watchCards(groupId);
});

// ---------------------------------------------------------------------------
// Section header (series or "Ohne Serie")
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.coverUrl,
    this.onTap,
    this.onDelete,
    super.key,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenH,
          AppSpacing.lg,
          AppSpacing.screenH,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            // Cover or icon
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(6)),
              child: SizedBox(
                width: 40,
                height: 40,
                child:
                    coverUrl != null
                        ? CachedNetworkImage(
                          imageUrl: coverUrl!,
                          fit: BoxFit.cover,
                        )
                        : ColoredBox(
                          color: AppColors.primarySoft.withValues(alpha: 0.3),
                          child: Icon(icon, size: 20, color: AppColors.primary),
                        ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // Title + count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: AppColors.error,
                tooltip: 'Löschen',
                visualDensity: VisualDensity.compact,
              ),
            if (onTap != null)
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Individual card tile (compact)
// ---------------------------------------------------------------------------

class _CardTile extends ConsumerWidget {
  const _CardTile({required this.card, this.showGroupAssign = false});

  final db.AudioCard card;

  /// Show group-assign action (for ungrouped cards).
  final bool showGroupAssign;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHeard = card.isHeard;

    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
      ),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(4)),
        child: SizedBox(
          width: 40,
          height: 40,
          child:
              card.coverUrl != null
                  ? Opacity(
                    opacity: isHeard ? 0.5 : 1.0,
                    child: CachedNetworkImage(
                      imageUrl: card.coverUrl!,
                      fit: BoxFit.cover,
                    ),
                  )
                  : ColoredBox(
                    color: AppColors.surfaceDim,
                    child: Icon(
                      Icons.music_note_rounded,
                      size: 18,
                      color:
                          isHeard
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
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
          color: isHeard ? AppColors.textSecondary : AppColors.textPrimary,
        ),
      ),
      subtitle:
          card.episodeNumber != null
              ? Text(
                'Folge ${card.episodeNumber}',
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              )
              : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card.provider != 'spotify')
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ProviderBadge(provider: card.provider),
            ),
          if (isHeard)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(
                Icons.check_circle_rounded,
                size: 16,
                color: AppColors.success,
              ),
            ),
          if (showGroupAssign)
            IconButton(
              onPressed: () => _showGroupPicker(context, ref, card),
              icon: const Icon(Icons.layers_rounded, size: 20),
              color: AppColors.primary,
              tooltip: 'Serie zuweisen',
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            onPressed: () => _confirmDelete(context, ref, card),
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: AppColors.error,
            tooltip: 'Entfernen',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.library_music_rounded,
            size: 48,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Noch keine Karten',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 16,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Hörspiel hinzufügen'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Auto-sort banner
// ---------------------------------------------------------------------------

class _AutoSortBanner extends ConsumerWidget {
  const _AutoSortBanner({
    required this.ungroupedCount,
    this.onTap,
  });

  final int ungroupedCount;

  /// Called when the banner body is tapped (scroll to ungrouped section).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenH,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: const BorderRadius.all(AppRadius.card),
        ),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          leading: const Icon(
            Icons.auto_awesome_rounded,
            color: AppColors.primary,
            size: 20,
          ),
          title: Text(
            ungroupedCount == 1
                ? '1 Karte ohne Serie'
                : '$ungroupedCount Karten ohne Serie',
            style: const TextStyle(
              fontFamily: 'Nunito',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: AppColors.primary,
            ),
          ),
          trailing: FilledButton(
            onPressed: () => unawaited(_runRetroactiveSort(context, ref)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Einordnen'),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared actions
// ---------------------------------------------------------------------------

void _confirmDeleteGroup(
  BuildContext context,
  WidgetRef ref,
  db.CardGroup group,
  int cardCount,
) {
  final label = cardCount == 1 ? '1 Karte' : '$cardCount Karten';
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Serie löschen?'),
            content: Text(
              '„${group.title}" und $label werden '
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
                  final count = await ref
                      .read(cardRepositoryProvider)
                      .deleteByGroup(group.id);
                  await ref.read(groupRepositoryProvider).delete(group.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            '${group.title} + $count Karten entfernt',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                  }
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

void _confirmDelete(BuildContext context, WidgetRef ref, db.AudioCard card) {
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Karte entfernen?'),
            content: Text(
              '„${card.customTitle ?? card.title}" wird aus der Sammlung entfernt.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  unawaited(ref.read(cardRepositoryProvider).delete(card.id));
                  ScaffoldMessenger.of(context)
                    ..clearSnackBars()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(
                          '${card.customTitle ?? card.title} entfernt',
                        ),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                ),
                child: const Text('Entfernen'),
              ),
            ],
          ),
    ),
  );
}

void _showGroupPicker(
  BuildContext context,
  WidgetRef ref,
  db.AudioCard card,
) {
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => _GroupPickerSheet(card: card),
    ),
  );
}

// ---------------------------------------------------------------------------
// Group picker bottom sheet
// ---------------------------------------------------------------------------

class _GroupPickerSheet extends ConsumerWidget {
  const _GroupPickerSheet({required this.card});

  final db.AudioCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);

    // Drag handle is provided by BottomSheetThemeData.showDragHandle.
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
              'Serie zuweisen',
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
                'Aus Serie entfernen',
                style: TextStyle(fontFamily: 'Nunito'),
              ),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(
                  ref.read(cardRepositoryProvider).removeFromGroup(card.id),
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
                                'Noch keine Serien vorhanden.',
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
                                    context.push(AppRoutes.parentManageGroups),
                                  );
                                },
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Serie erstellen'),
                              ),
                            ],
                          ),
                        )
                        : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
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
                                          .read(cardRepositoryProvider)
                                          .assignToGroup(
                                            cardId: card.id,
                                            groupId: group.id,
                                          ),
                                    );
                                  },
                                );
                              },
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(
                                Icons.add_rounded,
                                color: AppColors.primary,
                              ),
                              title: const Text(
                                'Neue Serie erstellen',
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
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create series and assign card
// ---------------------------------------------------------------------------

void _createAndAssign(
  BuildContext context,
  WidgetRef ref,
  db.AudioCard card,
) {
  final controller = TextEditingController();
  unawaited(
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Neue Serie'),
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
                    .read(groupRepositoryProvider)
                    .insert(title: title);
                await ref
                    .read(cardRepositoryProvider)
                    .assignToGroup(cardId: card.id, groupId: groupId);
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
                      .read(groupRepositoryProvider)
                      .insert(title: title);
                  await ref
                      .read(cardRepositoryProvider)
                      .assignToGroup(cardId: card.id, groupId: groupId);
                },
                child: const Text('Erstellen'),
              ),
            ],
          ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Retroactive series sorting
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Sort result dialog — lists matched series with links to group editor
// ---------------------------------------------------------------------------

class _SortResultDialog extends StatelessWidget {
  const _SortResultDialog({
    required this.seriesMatches,
    required this.seriesGroupIds,
    required this.totalMatched,
  });

  /// Series title → number of cards assigned.
  final Map<String, int> seriesMatches;

  /// Series title → group ID.
  final Map<String, String> seriesGroupIds;

  final int totalMatched;

  @override
  Widget build(BuildContext context) {
    final seriesCount = seriesMatches.length;
    final sortedTitles =
        seriesMatches.keys.toList()
          ..sort((a, b) => seriesMatches[b]!.compareTo(seriesMatches[a]!));

    return AlertDialog(
      title: const Text('Serien einordnen'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$totalMatched Karten zu $seriesCount '
              '${seriesCount == 1 ? 'Serie' : 'Serien'} sortiert.',
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: sortedTitles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final title = sortedTitles[index];
                  final count = seriesMatches[title]!;
                  final groupId = seriesGroupIds[title]!;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.auto_stories_rounded,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      '$count ${count == 1 ? 'Karte' : 'Karten'}',
                      style: const TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.textSecondary,
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(
                        context.push(AppRoutes.parentGroupEdit(groupId)),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Retroactive series sorting
// ---------------------------------------------------------------------------

Future<void> _runRetroactiveSort(BuildContext context, WidgetRef ref) async {
  final catalog = ref.read(catalogServiceProvider).value;
  if (catalog == null) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Katalog noch nicht geladen.')),
      );
    return;
  }

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('Karten werden sortiert…'),
              ],
            ),
          ),
    ),
  );

  try {
    final cardRepo = ref.read(cardRepositoryProvider);
    final groupRepo = ref.read(groupRepositoryProvider);
    final ungrouped = await cardRepo.getUngrouped();

    final grouped = <String, String>{}; // seriesTitle → groupId
    final groupedCounts = <String, int>{}; // seriesTitle → card count
    var matchCount = 0;

    for (final card in ungrouped) {
      final artistIds =
          card.spotifyArtistIds
              ?.split(',')
              .where((s) => s.isNotEmpty)
              .toList() ??
          const [];
      final match = catalog.match(card.title, albumArtistIds: artistIds);
      if (match == null) continue;

      final title = match.series.title;
      if (!grouped.containsKey(title)) {
        final existing = await groupRepo.findByTitle(title);
        grouped[title] = existing?.id ?? await groupRepo.insert(title: title);
      }

      await cardRepo.assignToGroup(
        cardId: card.id,
        groupId: grouped[title]!,
        episodeNumber: match.episodeNumber,
      );
      groupedCounts[title] = (groupedCounts[title] ?? 0) + 1;
      matchCount++;
    }

    Log.info(
      _tag,
      'Retroactive sort complete',
      data: {
        'ungrouped': ungrouped.length,
        'matched': matchCount,
        'series': grouped.length,
      },
    );

    if (context.mounted) Navigator.of(context).pop();

    if (context.mounted) {
      if (matchCount == 0) {
        unawaited(
          showDialog<void>(
            context: context,
            builder:
                (_) => AlertDialog(
                  title: const Text('Serien einordnen'),
                  content: const Text(
                    'Keine Karten konnten zugeordnet werden.\n'
                    'Tipp: Karten ohne Serienname im Titel müssen '
                    'manuell einer Serie zugewiesen werden.',
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
          ),
        );
      } else {
        unawaited(
          showDialog<void>(
            context: context,
            builder:
                (_) => _SortResultDialog(
                  seriesMatches: groupedCounts,
                  seriesGroupIds: grouped,
                  totalMatched: matchCount,
                ),
          ),
        );
      }
    }
  } on Exception catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    Log.error(_tag, 'Retroactive sort failed', exception: e);
  }
}
