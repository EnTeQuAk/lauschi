import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/cards/widgets/audio_card.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/widgets/now_playing_bar.dart';

/// The single kid-facing screen: card grid + now-playing bar.
///
/// No tabs, no menus, no navigation hierarchy.
/// Album art cards on a warm cream background. Tap to play.
class KidHomeScreen extends ConsumerWidget {
  const KidHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardsAsync = ref.watch(allCardsProvider);
    final playerState = ref.watch(playerNotifierProvider);
    final playerNotifier = ref.read(playerNotifierProvider.notifier);

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
                  // Parent mode button — intentionally subtle
                  IconButton(
                    onPressed: () => context.push(AppRoutes.pinEntry),
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
            // Card grid
            Expanded(
              child: cardsAsync.when(
                data: (cards) => cards.isEmpty
                    ? const _EmptyState()
                    : _CardGrid(
                        cards: cards,
                        activeUri: playerNotifier.activeContextUri,
                        isPlaying: playerState.isPlaying,
                        // Show active state when playing or paused with a track
                        isActive: playerState.track != null,
                        onCardTap: (card) =>
                            playerNotifier.playCard(card.providerUri),
                      ),
                loading: () => const Center(
                  child: CircularProgressIndicator(),
                ),
                error: (_, _) => const Center(
                  child: Icon(
                    Icons.error_outline_rounded,
                    size: 48,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
            // Now-playing bar
            if (playerState.track != null)
              NowPlayingBar(
                state: playerState,
                onTap: () => context.push(AppRoutes.player),
                onTogglePlay: playerNotifier.togglePlay,
              ),
          ],
        ),
      ),
    );
  }
}

class _CardGrid extends StatelessWidget {
  const _CardGrid({
    required this.cards,
    required this.activeUri,
    required this.isPlaying,
    required this.isActive,
    required this.onCardTap,
  });

  final List<db.Card> cards;
  final String? activeUri;
  final bool isPlaying;
  final bool isActive;
  final void Function(db.Card card) onCardTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 3 columns on phone, 4 on large phone, 5 on tablet
        final columns = constraints.maxWidth < 600
            ? 3
            : constraints.maxWidth < 900
                ? 4
                : 5;

        return GridView.builder(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenH,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
            // Square art + 8dp gap + 2 lines of text (~40dp)
            childAspectRatio: 0.7,
          ),
          itemCount: cards.length,
          itemBuilder: (context, index) {
            final card = cards[index];
            final isCurrentCard =
                isActive && activeUri == card.providerUri;

            return AudioCard(
              key: ValueKey(card.id),
              title: card.customTitle ?? card.title,
              coverUrl: card.coverUrl,
              isPlaying: isCurrentCard && isPlaying,
              isPaused: isCurrentCard && !isPlaying,
              onTap: () => onCardTap(card),
            );
          },
        );
      },
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
            const Icon(
              Icons.library_music_rounded,
              size: 72,
              color: AppColors.primarySoft,
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
              onPressed: () => context.push(AppRoutes.pinEntry),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Hörspiel hinzufügen'),
            ),
          ],
        ),
      ),
    );
  }
}
