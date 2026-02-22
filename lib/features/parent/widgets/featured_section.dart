import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_image.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/featured_shows.dart';
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/theme/app_theme.dart';

const _tag = 'FeaturedSection';

/// How recently an item must be published to show the "Neu" badge.
const _newBadgeMaxAge = Duration(days: 14);

// ── Shared add logic ────────────────────────────────────────────────────────

/// Add all parts of a featured item to the collection.
Future<void> _addFeaturedItem(
  BuildContext context,
  WidgetRef ref,
  FeaturedItem item,
) async {
  final existingUris = ref.read(existingCardUrisProvider);
  if (item.parts.every((p) => existingUris.contains(p.providerUri))) return;

  final importer = ref.read(contentImporterProvider.notifier);
  final cards =
      item.parts
          .where((p) => p.bestAudioUrl != null)
          .map(_ardPendingCard)
          .toList();

  try {
    final result = await importer.importToGroup(
      groupTitle: item.title,
      groupCoverUrl: ardImageUrl(item.imageUrl),
      cards: cards,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${result.added} Folgen zu ${item.title} hinzugefügt',
          ),
        ),
      );
    }
  } on Exception catch (e) {
    Log.error(_tag, 'Failed to add featured item', exception: e);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler: $e')),
      );
    }
  }
}

// ── Hero card ───────────────────────────────────────────────────────────────

/// Large hero card for the newest featured item. Full-width cover image
/// with title, publisher, duration, and availability countdown.
class FeaturedHeroCard extends ConsumerWidget {
  const FeaturedHeroCard({required this.item, super.key});

  final FeaturedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = ardImageUrl(item.imageUrl, width: 800);
    final daysLeft = _daysUntilExpiry(item.endDate);
    final existingUris = ref.watch(existingCardUrisProvider);
    final isImporting = ref.watch(contentImporterProvider);
    final allAdded = item.parts.every(
      (p) => existingUris.contains(p.providerUri),
    );
    final isNew = DateTime.now().difference(item.publishDate) < _newBadgeMaxAge;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(AppRadius.card),
        child: Stack(
          children: [
            // Cover image
            AspectRatio(
              aspectRatio: 16 / 9,
              child:
                  imageUrl != null
                      ? CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        color: Colors.black.withAlpha(100),
                        colorBlendMode: BlendMode.darken,
                      )
                      : const ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Center(
                          child: Icon(Icons.auto_stories_rounded, size: 48),
                        ),
                      ),
            ),

            // Text overlay
            Positioned(
              left: AppSpacing.md,
              right: AppSpacing.md,
              bottom: AppSpacing.md,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // "Neu" badge — only for recently published items
                  if (isNew)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '🌟 Neu',
                        style: TextStyle(
                          fontFamily: 'Nunito',
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textOnPrimary,
                        ),
                      ),
                    ),
                  if (isNew) const SizedBox(height: AppSpacing.xs),

                  // Title
                  Text(
                    item.title,
                    style: const TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),

                  // Subtitle: publisher · parts · duration
                  Text(
                    _heroSubtitle(item),
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 12,
                      color: Colors.white.withAlpha(200),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.sm),

                  // Bottom row: expiry + add button
                  Row(
                    children: [
                      if (daysLeft != null) _ExpiryChip(daysLeft: daysLeft),
                      const Spacer(),
                      if (allAdded)
                        const Icon(
                          Icons.check_circle,
                          color: AppColors.success,
                          size: 20,
                        )
                      else
                        _AddButton(
                          onPressed:
                              isImporting
                                  ? null
                                  : () => _addFeaturedItem(context, ref, item),
                          isLoading: isImporting,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _heroSubtitle(FeaturedItem item) {
    final parts = <String>[];
    if (item.publisher != null) parts.add(item.publisher!);
    if (item.isMultiPart) parts.add('${item.parts.length} Teile');
    parts.add(_formatDuration(item.totalDurationSeconds));
    return parts.join(' · ');
  }
}

// ── Horizontal scroll section ───────────────────────────────────────────────

/// Horizontal scrolling section showing featured items.
class FeaturedScrollSection extends ConsumerWidget {
  const FeaturedScrollSection({required this.items, super.key});

  final List<FeaturedItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
          child: Text(
            'HÖRSPIEL-SCHÄTZE',
            style: TextStyle(
              fontFamily: 'Nunito',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 200,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
            itemBuilder:
                (context, index) => _FeaturedTile(
                  item: items[index],
                ),
          ),
        ),
      ],
    );
  }
}

class _FeaturedTile extends ConsumerWidget {
  const _FeaturedTile({required this.item});

  final FeaturedItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageUrl = ardImageUrl(item.imageUrl, width: 300);
    final daysLeft = _daysUntilExpiry(item.endDate);
    final existingUris = ref.watch(existingCardUrisProvider);
    final allAdded = item.parts.every(
      (p) => existingUris.contains(p.providerUri),
    );

    return GestureDetector(
      onTap: allAdded ? null : () => _addFeaturedItem(context, ref, item),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.all(AppRadius.card),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (imageUrl != null)
                      CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                      )
                    else
                      const ColoredBox(
                        color: AppColors.surfaceDim,
                        child: Center(
                          child: Icon(Icons.auto_stories_rounded),
                        ),
                      ),
                    if (allAdded)
                      ColoredBox(
                        color: Colors.black.withAlpha(120),
                        child: const Center(
                          child: Icon(
                            Icons.check_circle,
                            color: AppColors.success,
                            size: 28,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),

            // Title
            Text(
              item.title,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),

            // Duration / parts
            Text(
              _tileSubtitle(item),
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 10,
                color: AppColors.textSecondary,
              ),
            ),

            // Expiry
            if (daysLeft != null)
              Text(
                'Noch $daysLeft T.',
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color:
                      daysLeft <= 14
                          ? AppColors.warning
                          : AppColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _tileSubtitle(FeaturedItem item) {
    if (item.isMultiPart) {
      return '${item.parts.length} Teile · ${_formatDuration(item.totalDurationSeconds)}';
    }
    return _formatDuration(item.totalDurationSeconds);
  }
}

// ── Shared widgets ──────────────────────────────────────────────────────────

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onPressed, this.isLoading = false});
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon:
            isLoading
                ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                : const Icon(Icons.add_rounded, size: 16),
        label: const Text(
          'Hinzufügen',
          style: TextStyle(fontFamily: 'Nunito', fontSize: 12),
        ),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          minimumSize: Size.zero,
        ),
      ),
    );
  }
}

class _ExpiryChip extends StatelessWidget {
  const _ExpiryChip({required this.daysLeft});
  final int daysLeft;

  @override
  Widget build(BuildContext context) {
    final color = daysLeft <= 14 ? AppColors.warning : Colors.white70;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Noch $daysLeft Tage',
        style: TextStyle(
          fontFamily: 'Nunito',
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

PendingCard _ardPendingCard(ArdItem item) {
  return PendingCard(
    title: item.title,
    providerUri: item.providerUri,
    cardType: 'episode',
    provider: 'ard_audiothek',
    coverUrl: ardImageUrl(item.imageUrl),
    episodeNumber: item.episodeNumber,
    audioUrl: item.bestAudioUrl,
    durationMs: item.durationMs,
    availableUntil: item.endDate,
  );
}

String _formatDuration(int seconds) {
  final m = seconds ~/ 60;
  if (m < 60) return '$m Min.';
  final h = m ~/ 60;
  final rm = m % 60;
  if (rm == 0) return '${h}h';
  return '${h}h ${rm}m';
}

int? _daysUntilExpiry(DateTime? endDate) {
  if (endDate == null) return null;
  final days = endDate.difference(DateTime.now()).inDays;
  if (days < 0) return null;
  return days;
}
