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

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _interpolatedPositionMs = 0;
  DateTime _lastTickTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    unawaited(_ticker.start());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final state = ref.read(playerNotifierProvider);

    // Snap to server position on large drift or pause
    if ((state.positionMs - _interpolatedPositionMs).abs() > 2000 ||
        !state.isPlaying) {
      if (_interpolatedPositionMs != state.positionMs) {
        setState(() => _interpolatedPositionMs = state.positionMs);
      }
      _lastTickTime = DateTime.now();
      return;
    }

    if (state.isPlaying && state.durationMs > 0) {
      final now = DateTime.now();
      final deltaMs = now.difference(_lastTickTime).inMilliseconds;
      _lastTickTime = now;
      setState(() {
        _interpolatedPositionMs = (_interpolatedPositionMs + deltaMs)
            .clamp(0, state.durationMs);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerNotifierProvider);
    final notifier = ref.read(playerNotifierProvider.notifier);
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
              const SizedBox(height: AppSpacing.lg),
              // Progress bar with interpolated position
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                ),
                child: _ProgressBar(
                  positionMs: _interpolatedPositionMs,
                  durationMs: state.durationMs,
                  onSeek: (ms) {
                    _interpolatedPositionMs = ms;
                    unawaited(notifier.seek(ms));
                  },
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
            child: artworkUrl != null
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
    );
  }
}
