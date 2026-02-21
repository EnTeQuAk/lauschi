import 'dart:async' show Timer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/connectivity/connectivity_provider.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';

import 'package:lauschi/features/cards/widgets/audio_card.dart';
import 'package:lauschi/features/cards/widgets/group_card.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';

/// Album playback progress 0.0–1.0 based on stored track position.
double _albumProgress(db.AudioCard card) {
  if (card.isHeard || card.totalTracks <= 0 || card.lastTrackNumber <= 0) {
    return 0;
  }
  return (card.lastTrackNumber / card.totalTracks).clamp(0.0, 1.0);
}

/// The single kid-facing screen: group + card grid + now-playing bar.
///
/// Groups appear as series tiles (drill-down to episodes).
/// Ungrouped cards appear as regular audio cards.
class KidHomeScreen extends ConsumerWidget {
  const KidHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(allGroupsProvider);
    final ungroupedAsync = ref.watch(ungroupedCardsProvider);
    // Only rebuild for play state / track changes, not position updates.
    final playerState = ref.watch(
      playerProvider.select(
        (s) => (
          isPlaying: s.isPlaying,
          isReady: s.isReady,
          hasTrack: s.track != null,
          error: s.error,
          activeContextUri: s.activeContextUri,
        ),
      ),
    );
    final playerNotifier = ref.read(playerProvider.notifier);
    final isOnline = ref.watch(isOnlineProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenH,
                AppSpacing.lg,
                AppSpacing.screenH,
                AppSpacing.md,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Meine Hörspiele',
                    style: TextStyle(
                      fontFamily: 'Nunito',
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                  IconButton(
                    onPressed: () => context.push(AppRoutes.parentDashboard),
                    icon: const Icon(Icons.settings_rounded),
                    iconSize: 22,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      foregroundColor: AppColors.textSecondary,
                    ),
                    tooltip: 'Eltern-Bereich',
                  ),
                ],
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

            // Connecting indicator — subtle, doesn't take prime real estate.
            if (!playerState.isReady && isOnline)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.xs),
                child: SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    color: AppColors.primary,
                  ),
                ),
              ),

            // Grid
            Expanded(
              child: _combineAsync(groupsAsync, ungroupedAsync, (
                groups,
                ungrouped,
              ) {
                if (groups.isEmpty && ungrouped.isEmpty) {
                  return const _EmptyState();
                }
                return _HomeGrid(
                  groups: groups,
                  ungrouped: ungrouped,
                  activeUri: playerState.activeContextUri,
                  isPlaying: playerState.isPlaying,
                  isActive: playerState.hasTrack,
                  onCardTap:
                      playerState.isReady
                          ? (card) => playerNotifier.playCard(card.id)
                          : null,
                  onGroupTap:
                      (group) => context.push(AppRoutes.groupDetail(group.id)),
                );
              }),
            ),

            // Error feedback
            if (playerState.error != null)
              _ErrorBanner(
                message: playerState.error!,
                onDismiss: () => ref.read(playerProvider.notifier).clearError(),
              ),

            // Now-playing bar
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
                  playerState.hasTrack
                      ? Consumer(
                        builder: (context, ref, _) {
                          final fullState = ref.watch(playerProvider);
                          return NowPlayingBar(
                            key: const ValueKey('now-playing'),
                            state: fullState,
                            onTap: () => context.push(AppRoutes.player),
                            onTogglePlay: playerNotifier.togglePlay,
                          );
                        },
                      )
                      : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  /// Combine two AsyncValues. Shows loading/error if either isn't ready.
  Widget _combineAsync<A, B>(
    AsyncValue<A> a,
    AsyncValue<B> b,
    Widget Function(A, B) builder,
  ) {
    if (a is AsyncLoading || b is AsyncLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (a is AsyncError || b is AsyncError) {
      return const Center(
        child: Icon(
          Icons.error_outline_rounded,
          size: 48,
          color: AppColors.textSecondary,
        ),
      );
    }
    return builder(a.requireValue, b.requireValue);
  }
}

class _HomeGrid extends StatelessWidget {
  const _HomeGrid({
    required this.groups,
    required this.ungrouped,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
    required this.onGroupTap,
  });

  final List<db.CardGroup> groups;
  final List<db.AudioCard> ungrouped;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.AudioCard)? onCardTap;
  final void Function(db.CardGroup) onGroupTap;

  @override
  Widget build(BuildContext context) {
    final itemCount = groups.length + ungrouped.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth < 600
                ? 3
                : constraints.maxWidth < 900
                ? 4
                : 5;

        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenH),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
            childAspectRatio: 0.68,
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) {
            // Groups first, then ungrouped cards
            if (index < groups.length) {
              final group = groups[index];
              return _GroupGridItem(
                key: ValueKey('group-${group.id}'),
                group: group,
                onTap: () => onGroupTap(group),
              );
            }
            final card = ungrouped[index - groups.length];
            final isCurrentCard = isActive && activeUri == card.providerUri;
            return AudioCard(
              key: ValueKey(card.id),
              title: card.customTitle ?? card.title,
              coverUrl: card.coverUrl,
              isPlaying: isCurrentCard && isPlaying,
              isPaused: isCurrentCard && !isPlaying,
              isHeard: card.isHeard,
              progress: _albumProgress(card),
              onTap: onCardTap != null ? () => onCardTap!(card) : () {},
            );
          },
        );
      },
    );
  }
}

/// Grid item that watches its own episode count — clean separation.
class _GroupGridItem extends ConsumerWidget {
  const _GroupGridItem({required this.group, required this.onTap, super.key});

  final db.CardGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressMap = ref.watch(groupProgressProvider);
    final stats = progressMap[group.id];
    final total = stats?.total ?? 0;
    final heard = stats?.heard ?? 0;
    final progress = total > 0 ? (heard / total) : 0.0;

    return GroupCard(
      title: group.title,
      episodeCount: total,
      coverUrl: group.coverUrl,
      progress: progress,
      contentType: group.contentType,
      onTap: onTap,
    );
  }
}

class _ErrorBanner extends StatefulWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

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
              widget.message,
              style: const TextStyle(
                fontFamily: 'Nunito',
                fontSize: 14,
                color: AppColors.error,
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onDismiss,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/branding/lauschi-mascot.png',
              width: 140,
              height: 140,
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Füge dein erstes Hörspiel hinzu',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Öffne den Eltern-Bereich, um Hörspiele hinzuzufügen.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 15,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () => context.push(AppRoutes.parentDashboard),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Hörspiel hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
