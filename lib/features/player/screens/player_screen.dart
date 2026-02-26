import 'dart:async' show unawaited;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Full-screen player with large album art, controls, and progress bar.
///
/// Expands from the now-playing bar via hero animation on the album art.
/// Swipe down or tap the collapse handle to return to the card grid.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  @override
  Widget build(BuildContext context) {
    final error = ref.watch(playerProvider.select((s) => s.error));

    // Show friendly screen for expired/unavailable content.
    if (error == 'content_unavailable' ||
        error == 'Diese Geschichte ist leider nicht mehr verfügbar') {
      return const _ContentUnavailableScreen();
    }

    final state = ref.watch(
      playerProvider.select(
        (s) => (
          track: s.track,
          isPlaying: s.isPlaying,
          isAdvancing: s.isAdvancing,
          nextEpisodeCoverUrl: s.nextEpisodeCoverUrl,
          durationMs: s.durationMs,
          positionMs: s.positionMs,
        ),
      ),
    );
    final notifier = ref.read(playerProvider.notifier);
    final track = state.track;

    return Scaffold(
      body: SafeArea(
        child: GestureDetector(
          onVerticalDragEnd: (details) {
            // Swipe down to close
            if (details.primaryVelocity != null &&
                details.primaryVelocity! > 300) {
              Navigator.of(context).pop();
            }
          },
          child: Column(
            children: [
              // Collapse handle
              const _CollapseHandle(),
              // Album art
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xxl,
                    ),
                    child: _AlbumArt(artworkUrl: track?.artworkUrl),
                  ),
                ),
              ),
              // Track info
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                ),
                child: _TrackInfo(track: track),
              ),
              // Auto-advance indicator: skip icon + next cover thumbnail
              if (state.isAdvancing)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.skip_next_rounded,
                        size: 24,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(6),
                        ),
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child:
                              state.nextEpisodeCoverUrl != null
                                  ? CachedNetworkImage(
                                    imageUrl: state.nextEpisodeCoverUrl!,
                                    fit: BoxFit.cover,
                                  )
                                  : const ColoredBox(
                                    color: AppColors.surfaceDim,
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      size: 20,
                                    ),
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              // Progress bar with its own ticker for smooth interpolation.
              // Isolated to avoid rebuilding album art / controls at 60fps.
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                ),
                child: _InterpolatedProgress(
                  onSeek: (ms) => unawaited(notifier.seek(ms)),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Controls
              _PlayerControls(
                isPlaying: state.isPlaying,
                onPrevious: notifier.prevTrack,
                onTogglePlay: notifier.togglePlay,
                onNext: notifier.nextTrack,
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

/// Progress bar with its own ticker — only this widget rebuilds at 60fps.
class _InterpolatedProgress extends ConsumerStatefulWidget {
  const _InterpolatedProgress({required this.onSeek});
  final ValueChanged<int> onSeek;

  @override
  ConsumerState<_InterpolatedProgress> createState() =>
      _InterpolatedProgressState();
}

class _InterpolatedProgressState extends ConsumerState<_InterpolatedProgress>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _position = ValueNotifier<int>(0);

  /// Last position reported by the SDK. When this changes, we re-anchor
  /// the interpolation to the new server position and interpolate forward
  /// from there. Prevents drift between ticker and SDK from causing
  /// periodic backward snaps.
  int _anchorMs = 0;
  DateTime _anchorTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    unawaited(_ticker.start());
  }

  @override
  void dispose() {
    _ticker.dispose();
    _position.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final state = ref.read(playerProvider);
    final serverMs = state.positionMs;

    // Re-anchor when the SDK reports a new position (different from our
    // last anchor). This happens every few seconds on state_changed events.
    if (serverMs != _anchorMs) {
      _anchorMs = serverMs;
      _anchorTime = DateTime.now();
    }

    if (!state.isPlaying || state.durationMs <= 0) {
      _position.value = serverMs;
      return;
    }

    // Interpolate forward from the anchor at real-time speed.
    final deltaMs = DateTime.now().difference(_anchorTime).inMilliseconds;
    _position.value = (_anchorMs + deltaMs).clamp(0, state.durationMs);
  }

  /// Re-anchor interpolation to a user-initiated seek position.
  /// Without this, the next _onTick would overwrite _position with the
  /// old anchor+delta, causing the slider to snap back visually until
  /// the SDK confirms the new position.
  void _seekTo(int ms) {
    _anchorMs = ms;
    _anchorTime = DateTime.now();
    _position.value = ms;
    widget.onSeek(ms);
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = ref.watch(
      playerProvider.select((s) => s.durationMs),
    );
    return ValueListenableBuilder<int>(
      valueListenable: _position,
      builder:
          (context, positionMs, _) => _ProgressBar(
            positionMs: positionMs,
            durationMs: durationMs,
            onSeek: _seekTo,
          ),
    );
  }
}

class _CollapseHandle extends StatelessWidget {
  const _CollapseHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          const SizedBox(width: AppSpacing.xs),
          // Close button — large touch target for kids
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            iconSize: 32,
            style: IconButton.styleFrom(
              minimumSize: const Size(56, 56),
              foregroundColor: AppColors.textSecondary,
            ),
            tooltip: 'Zurück',
          ),
          // Drag handle hint
          Expanded(
            child: Center(
              child: Container(
                width: 36,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.all(AppRadius.pill),
                ),
              ),
            ),
          ),
          // Balance the row
          const SizedBox(width: 56 + AppSpacing.xs),
        ],
      ),
    );
  }
}

class _AlbumArt extends StatelessWidget {
  const _AlbumArt({this.artworkUrl});

  final String? artworkUrl;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
      child: AspectRatio(
        aspectRatio: 1,
        child: Hero(
          tag: 'player-artwork',
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child:
                artworkUrl != null
                    ? CachedNetworkImage(
                      imageUrl: artworkUrl!,
                      fit: BoxFit.cover,
                    )
                    : const ColoredBox(
                      color: AppColors.surfaceDim,
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 72,
                        color: AppColors.textSecondary,
                      ),
                    ),
          ),
        ),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({this.track});

  final TrackInfo? track;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          track?.name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontWeight: FontWeight.w700,
            fontSize: 22,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          track?.artist ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Nunito',
            fontSize: 15,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.positionMs,
    required this.durationMs,
    required this.onSeek,
  });

  final int positionMs;
  final int durationMs;
  final void Function(int positionMs) onSeek;

  double get _progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SliderTheme(
          data: const SliderThemeData(
            trackHeight: 6,
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.surfaceDim,
            thumbColor: AppColors.primary,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 20),
            trackShape: RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: _progress,
            onChanged: (value) {
              if (durationMs > 0) {
                onSeek((value * durationMs).round());
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(positionMs),
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                _formatDuration(durationMs),
                style: const TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _formatDuration(int ms) {
    final total = Duration(milliseconds: ms);
    final minutes = total.inMinutes;
    final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls({
    required this.isPlaying,
    required this.onPrevious,
    required this.onTogglePlay,
    required this.onNext,
  });

  final bool isPlaying;
  final VoidCallback onPrevious;
  final VoidCallback onTogglePlay;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Previous — 56dp target (school-age minimum)
        IconButton(
          onPressed: onPrevious,
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: 36,
          style: IconButton.styleFrom(
            minimumSize: const Size(56, 56),
            foregroundColor: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        // Play/pause — 72dp target (preschooler minimum)
        _PlayPauseButton(
          isPlaying: isPlaying,
          onPressed: onTogglePlay,
        ),
        const SizedBox(width: AppSpacing.lg),
        // Next — 56dp target
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: 36,
          style: IconButton.styleFrom(
            minimumSize: const Size(56, 56),
            foregroundColor: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.isPlaying,
    required this.onPressed,
  });

  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Semantics(
        label: isPlaying ? 'Pause' : 'Abspielen',
        button: true,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
          ),
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 40,
            color: AppColors.textOnPrimary,
          ),
        ),
      ),
    );
  }
}

// ── Expired / unavailable content screen ────────────────────────────────────

class _ContentUnavailableScreen extends ConsumerWidget {
  const _ContentUnavailableScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _CollapseHandle(),
            const Spacer(),
            const Text(
              '🐦',
              style: TextStyle(fontSize: 64),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Diese Geschichte ist\nweggeflogen',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Nunito',
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
              child: Text(
                'Aber keine Sorge, es gibt noch\nviele andere tolle Geschichten!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Nunito',
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () {
                ref.read(playerProvider.notifier).clearError();
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text(
                'Zurück',
                style: TextStyle(fontFamily: 'Nunito'),
              ),
            ),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}
