import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/nfc/nfc_pair_dialog.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/widgets/audio_card.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';

/// Album playback progress 0.0–1.0 based on stored track position.
/// Returns 0 for cards that haven't been started or are fully heard.
double _albumProgress(db.AudioCard card) {
  if (card.isHeard || card.totalTracks <= 0 || card.lastTrackNumber <= 0) {
    return 0;
  }
  return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
}

/// Group/series drill-down — shows all episodes in order.
///
/// Heard episodes are visually muted. First unheard episode is highlighted
/// as the "next" — a gentle nudge without being prescriptive.
class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupAsync = ref.watch(groupByIdProvider(groupId));
    final episodesAsync = ref.watch(groupEpisodesProvider(groupId));
    final nextUnheard = ref.watch(groupNextUnheardProvider(groupId));
    final playerState = ref.watch(playerProvider);
    final playerNotifier = ref.read(playerProvider.notifier);
    final isOnline = ref.watch(isOnlineProvider);
    final nfcEnabled =
        ref
            .watch(debugSettingsProvider)
            .whenOrNull(data: (s) => s.nfcEnabled) ??
        false;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header with back button + optional NFC pair action
            groupAsync.when(
              data:
                  (group) => _GroupHeader(
                    title: group?.title ?? '',
                    onBack: () => context.pop(),
                    onNfcPair:
                        nfcEnabled && group != null
                            ? () => showNfcPairDialog(
                              context,
                              ref: ref,
                              targetType: 'group',
                              targetId: group.id,
                              targetLabel: group.title,
                            )
                            : null,
                  ),
              loading: () => _GroupHeader(title: '', onBack: context.pop),
              error: (_, _) => _GroupHeader(title: '', onBack: context.pop),
            ),

            // Offline indicator
            if (!isOnline)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenH,
                  vertical: AppSpacing.sm,
                ),
                color: AppColors.surfaceDim,
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    SizedBox(width: AppSpacing.xs),
                    Text(
                      'Kein Internet',
                      style: TextStyle(
                        fontFamily: 'Nunito',
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

            // Episode grid
            Expanded(
              child: episodesAsync.when(
                data: (episodes) {
                  if (episodes.isEmpty) {
                    return const _EmptyGroupState();
                  }
                  final nextId = nextUnheard?.id;
                  return _EpisodeGrid(
                    episodes: episodes,
                    nextUnheardId: nextId,
                    activeUri: playerState.activeContextUri,
                    isPlaying: playerState.isPlaying,
                    isActive: playerState.track != null,
                    onCardTap: (card) => playerNotifier.playCard(card.id),
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error:
                    (_, _) => const Center(
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 48,
                        color: AppColors.textSecondary,
                      ),
                    ),
              ),
            ),

            // Error feedback
            if (playerState.error != null)
              _ErrorBanner(
                message: playerState.error!,
                onDismiss: () => ref.read(playerProvider.notifier).clearError(),
              ),

            // Now-playing bar (same as home)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder:
                  (child, animation) => SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                    child: child,
                  ),
              child:
                  playerState.track != null
                      ? NowPlayingBar(
                        key: const ValueKey('now-playing'),
                        state: playerState,
                        onTap: () => context.push(AppRoutes.player),
                        onTogglePlay: playerNotifier.togglePlay,
                      )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.onBack,
    this.onNfcPair,
  });

  final String title;
  final VoidCallback onBack;

  /// If non-null, shows an NFC pair button in the header.
  final VoidCallback? onNfcPair;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.screenH,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            iconSize: 24,
            style: IconButton.styleFrom(
              minimumSize: const Size(44, 44),
              foregroundColor: AppColors.textSecondary,
            ),
            tooltip: 'Zurück',
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (onNfcPair != null)
            IconButton(
              onPressed: onNfcPair,
              icon: const Icon(Icons.nfc_rounded),
              iconSize: 22,
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: AppColors.textSecondary,
              ),
              tooltip: 'NFC-Tag verknüpfen',
            ),
        ],
      ),
    );
  }
}

class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
    this.nextUnheardId,
  });

  final List<db.AudioCard> episodes;
  final String? nextUnheardId;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.AudioCard card) onCardTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = kidGridColumns(constraints.maxWidth);

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenH,
            AppSpacing.sm,
            AppSpacing.screenH,
            AppSpacing.xxl,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final card = episodes[index];
            final isCurrentCard = isActive && activeUri == card.providerUri;
            final isNext = card.id == nextUnheardId;

            return Stack(
              clipBehavior: Clip.none,
              children: [
                AudioCard(
                  key: ValueKey(card.id),
                  title: card.customTitle ?? card.title,
                  coverUrl: card.coverUrl,
                  isPlaying: isCurrentCard && isPlaying,
                  isPaused: isCurrentCard && !isPlaying,
                  isHeard: card.isHeard,
                  progress: _albumProgress(card),
                  kidMode: true,
                  episodeNumber: card.episodeNumber,
                  onTap: () => onCardTap(card),
                ),
                // "Weiter" badge on next unheard episode
                if (isNext)
                  Positioned(
                    top: -4,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.all(AppRadius.pill),
                        ),
                        child: const Text(
                          '▶ Weiter',
                          style: TextStyle(
                            fontFamily: 'Nunito',
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textOnPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenH,
        vertical: AppSpacing.sm,
      ),
      color: AppColors.error.withValues(alpha: 0.1),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.error,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.error,
              ),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: AppColors.error,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class _EmptyGroupState extends StatelessWidget {
  const _EmptyGroupState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.layers_rounded, size: 48, color: AppColors.primarySoft),
            SizedBox(height: AppSpacing.md),
            Text(
              'Noch keine Folgen',
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 16,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Providers scoped to a group — manual StreamProviders to avoid Drift type
// resolution issues with riverpod_generator.
// ---------------------------------------------------------------------------

/// Cards in a specific group, ordered by episode number.
final groupEpisodesProvider = StreamProvider.family<List<db.AudioCard>, String>(
  (ref, groupId) {
    return ref.watch(groupRepositoryProvider).watchCards(groupId);
  },
);

/// The group metadata for a given ID — reactive to DB changes.
final groupByIdProvider = StreamProvider.family<db.CardGroup?, String>((
  ref,
  groupId,
) {
  return ref.watch(groupRepositoryProvider).watchById(groupId);
});

/// First unheard card in a group — reactive to episode changes.
final groupNextUnheardProvider = Provider.family<db.AudioCard?, String>((
  ref,
  groupId,
) {
  final episodes = ref.watch(groupEpisodesProvider(groupId)).value ?? [];
  for (final ep in episodes) {
    if (!ep.isHeard) return ep;
  }
  return null;
});
