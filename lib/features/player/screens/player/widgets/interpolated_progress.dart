import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_progress_bar.dart';

/// Progress bar with its own ticker; only this widget rebuilds at 60fps.
///
/// Interpolates between SDK-reported positions for smooth slider movement.
/// Uses the Ticker's monotonic elapsed duration instead of DateTime.now()
/// to avoid clock-jump bugs from NTP sync or manual time changes.
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
  Duration _anchorElapsed = Duration.zero;
  bool _scrubbing = false;

  /// Cached player state, updated via ref.listen in build().
  /// The ticker reads this instead of calling ref.read() per frame.
  PlaybackState _playerState = const PlaybackState();

  /// Last elapsed duration from the ticker, for re-anchoring in scrub/seek.
  Duration _lastElapsed = Duration.zero;

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
    _lastElapsed = elapsed;
    if (_scrubbing) return;

    final serverMs = _playerState.positionMs;

    if (serverMs != _anchorMs) {
      _anchorMs = serverMs;
      _anchorElapsed = elapsed;
    }

    _position.value = interpolatePosition(
      anchorMs: _anchorMs,
      elapsedMs: (elapsed - _anchorElapsed).inMilliseconds,
      durationMs: _playerState.durationMs,
      isPlaying: _playerState.isPlaying,
    );
  }

  void _reanchor(int ms) {
    _anchorMs = ms;
    _anchorElapsed = _lastElapsed;
    _position.value = ms;
  }

  /// Update local position during drag without sending a seek command.
  void _scrubTo(int ms) {
    _scrubbing = true;
    _reanchor(ms);
  }

  /// Commit the seek when the user releases the slider.
  void _seekTo(int ms) {
    _scrubbing = false;
    _reanchor(ms);
    widget.onSeek(ms);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider, (_, next) => _playerState = next);
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
