import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/nfc/nfc_pair_dialog.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/settings/debug_settings.dart';
import 'package:lauschi/core/settings/kid_settings.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';
import 'package:lauschi/features/tiles/widgets/audio_tile.dart';

/// Album playback progress 0.0–1.0 based on stored track position.
/// Returns 0 for cards that haven't been started or are fully heard.
double _albumProgress(db.TileItem card) {
  if (card.isHeard || card.totalTracks <= 0 || card.lastTrackNumber <= 0) {
    return 0;
  }
  return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
}

/// Group/series drill-down — shows all episodes in order.
///
/// Heard episodes are visually muted. First unheard episode is highlighted
/// as the "next" — a gentle nudge without being prescriptive.
class TileDetailScreen extends ConsumerWidget {
  const TileDetailScreen({required this.tileId, super.key});

  final String tileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupAsync = ref.watch(tileByIdProvider(tileId));
    final episodesAsync = ref.watch(tileItemsProvider(tileId));
    final nextUnheard = ref.watch(tileNextUnheardProvider(tileId));
    final playerState = ref.watch(playerProvider);
    final playerNotifier = ref.read(playerProvider.notifier);
    final isOnline = ref.watch(isOnlineProvider);
    final nfcEnabled =
        ref
            .watch(debugSettingsProvider)
            .whenOrNull(data: (s) => s.nfcEnabled) ??
        false;
    final showTitles = ref.watch(showEpisodeTitlesProvider).value ?? false;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header with back button + optional NFC pair action
            groupAsync.when(
              data:
                  (group) => _GroupHeader(
                    title: group?.title ?? '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
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
              loading:
                  () => _GroupHeader(
                    title: '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
                  ),
              error:
                  (_, _) => _GroupHeader(
                    title: '',
                    onBack: () {
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(AppRoutes.kidHome);
                      }
                    },
                  ),
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
                    showEpisodeTitles: showTitles,
                    onCardTap: (card) {
                      unawaited(playerNotifier.playCard(card.id));
                      unawaited(context.push(AppRoutes.player));
                    },
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
                message: playerState.error!.message,
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
    this.showEpisodeTitles = false,
  });

  final List<db.TileItem> episodes;
  final String? nextUnheardId;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.TileItem card) onCardTap;
  final bool showEpisodeTitles;

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
                TileItem(
                  key: ValueKey(card.id),
                  title: card.customTitle ?? card.title,
                  coverUrl: card.coverUrl,
                  isPlaying: isCurrentCard && isPlaying,
                  isPaused: isCurrentCard && !isPlaying,
                  isHeard: card.isHeard,
                  progress: _albumProgress(card),
                  kidMode: true,
                  episodeNumber: card.episodeNumber,
                  showEpisodeTitles: showEpisodeTitles,
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
final tileItemsProvider = StreamProvider.family<List<db.TileItem>, String>(
  (ref, tileId) {
    return ref.watch(tileRepositoryProvider).watchItems(tileId);
  },
);

/// The group metadata for a given ID — reactive to DB changes.
final tileByIdProvider = StreamProvider.family<db.Tile?, String>((
  ref,
  tileId,
) {
  return ref.watch(tileRepositoryProvider).watchById(tileId);
});

/// The episode to show the "Weiter" badge on.
///
/// Priority:
/// 1. Most recently played in-progress episode (has saved position from DB,
///    meaning 30s play threshold was met)
/// 2. First unheard episode (sequential fallback)
final tileNextUnheardProvider = Provider.family<db.TileItem?, String>((
  ref,
  tileId,
) {
  final episodes = ref.watch(tileItemsProvider(tileId)).value ?? [];

  // Find the most recently played episode that's still in progress.
  // Only considers episodes with a saved position (30s threshold met).
  db.TileItem? inProgress;
  for (final ep in episodes) {
    if (!ep.isHeard && ep.lastPlayedAt != null && ep.lastPositionMs > 0) {
      if (inProgress == null ||
          ep.lastPlayedAt!.isAfter(inProgress.lastPlayedAt!)) {
        inProgress = ep;
      }
    }
  }
  if (inProgress != null) return inProgress;

  // Nothing in progress — first unheard episode.
  for (final ep in episodes) {
    if (!ep.isHeard) return ep;
  }
  return null;
});
