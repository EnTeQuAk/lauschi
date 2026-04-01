import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_progress_bar.dart';

/// Progress bar with its own ticker; only this widget rebuilds at 60fps.
///
/// Interpolates between SDK-reported positions for smooth slider movement.
class InterpolatedProgress extends ConsumerStatefulWidget {
  const InterpolatedProgress({required this.onSeek, super.key});
  final ValueChanged<int> onSeek;

  @override
  ConsumerState<InterpolatedProgress> createState() =>
      _InterpolatedProgressState();
}

class _InterpolatedProgressState extends ConsumerState<InterpolatedProgress>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _position = ValueNotifier<int>(0);

  /// Last position reported by the SDK. When this changes, we re-anchor
  /// the interpolation to the new server position and interpolate forward
  /// from there.
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

    if (serverMs != _anchorMs) {
      _anchorMs = serverMs;
      _anchorTime = DateTime.now();
    }

    if (!state.isPlaying || state.durationMs <= 0) {
      _position.value = serverMs;
      return;
    }

    final deltaMs = DateTime.now().difference(_anchorTime).inMilliseconds;
    _position.value = (_anchorMs + deltaMs).clamp(0, state.durationMs);
  }

  /// Update local position during drag without sending a seek command.
  void _scrubTo(int ms) {
    _anchorMs = ms;
    _anchorTime = DateTime.now();
    _position.value = ms;
  }

  /// Commit the seek when the user releases the slider.
  void _seekTo(int ms) {
    _scrubTo(ms);
    widget.onSeek(ms);
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = ref.watch(
      playerProvider.select((s) => s.durationMs),
    );
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: _position,
        builder:
            (context, positionMs, _) => PlayerProgressBar(
              positionMs: positionMs,
              durationMs: durationMs,
              onScrub: _scrubTo,
              onSeek: _seekTo,
            ),
      ),
    );
  }
}
