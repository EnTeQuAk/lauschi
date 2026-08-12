import 'dart:async' show Timer, unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/widgets/player_progress_bar.dart';

/// Progress bar driven by an AnimationController at 1x playback speed.
///
/// The controller animates linearly from 0.0 to 1.0 over the track's
/// duration. SDK position updates snap the controller to the server
/// value; play/pause starts and stops the animation.
class InterpolatedProgress extends ConsumerStatefulWidget {
  const InterpolatedProgress({required this.onSeek, super.key});
  final ValueChanged<int> onSeek;

  @override
  ConsumerState<InterpolatedProgress> createState() =>
      _InterpolatedProgressState();
}

class _InterpolatedProgressState extends ConsumerState<InterpolatedProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _scrubbing = false;

  /// Track the last SDK-reported position to avoid calling
  /// controller.value = x when nothing changed (the setter calls stop()
  /// internally, which would interrupt an in-progress animation).
  int _lastServerMs = -1;
  int _lastDurationMs = 0;

  /// After a seek, the backend may fire one or more state updates with
  /// the pre-seek position before the seek confirmation arrives. This
  /// would snap the slider back to the old position, then forward again.
  /// While set, position snaps are suppressed until the backend reports
  /// a position within 2s of the seek target, or [_pendingSeekTimer]
  /// gives up.
  int? _pendingSeekMs;

  /// Lifts the seek suppression if the target position is never
  /// reported (a failed seek that resumed elsewhere via recovery).
  /// Without it, suppression would stick forever and freeze the bar at
  /// the target while the audio plays from a different position.
  Timer? _pendingSeekTimer;
  static const _pendingSeekTimeout = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _pendingSeekTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _syncController(PlaybackState? _, PlaybackState state) {
    if (_scrubbing) return;

    final durationMs = state.durationMs;
    if (durationMs <= 0) {
      if (_controller.isAnimating) _controller.stop();
      return;
    }

    if (durationMs != _lastDurationMs) {
      _lastDurationMs = durationMs;
      _controller.duration = Duration(milliseconds: durationMs);
    }

    final serverMs = state.positionMs;
    if (_pendingSeekMs != null) {
      if ((serverMs - _pendingSeekMs!).abs() <= 2000) {
        _clearPendingSeek();
        _lastServerMs = serverMs;
      }
    } else if (serverMs != _lastServerMs) {
      _snapTo(serverMs, durationMs);
    }

    if (state.isPlaying && !_controller.isAnimating) {
      unawaited(_controller.forward());
    } else if (!state.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  /// Jump the controller to [ms] of [durationMs]. [trackServer] records
  /// it as the last confirmed server position; a scrub in progress
  /// passes false because the finger drag is not a confirmed position.
  void _snapTo(int ms, int durationMs, {bool trackServer = true}) {
    if (durationMs <= 0) return;
    if (trackServer) _lastServerMs = ms;
    _controller.value = (ms / durationMs).clamp(0.0, 1.0);
  }

  void _scrubTo(int ms) {
    _scrubbing = true;
    _controller.stop();
    _snapTo(ms, _lastDurationMs, trackServer: false);
  }

  void _seekTo(int ms) {
    _scrubbing = false;
    _pendingSeekMs = ms;
    _pendingSeekTimer?.cancel();
    _pendingSeekTimer = Timer(_pendingSeekTimeout, _giveUpPendingSeek);
    _snapTo(ms, _lastDurationMs);
    widget.onSeek(ms);
    if (ref.read(playerProvider).isPlaying && _lastDurationMs > 0) {
      unawaited(_controller.forward());
    }
  }

  void _clearPendingSeek() {
    _pendingSeekMs = null;
    _pendingSeekTimer?.cancel();
    _pendingSeekTimer = null;
  }

  /// The seek target was never confirmed: give up suppressing snaps and
  /// re-sync the bar to wherever playback actually is now. Only ever
  /// runs from a live timer, which means a pending seek is still set.
  void _giveUpPendingSeek() {
    _clearPendingSeek();
    final state = ref.read(playerProvider);
    _snapTo(state.positionMs, state.durationMs);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider, _syncController);
    final durationMs = ref.watch(
      playerProvider.select((s) => s.durationMs),
    );
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder:
            (context, _) => PlayerProgressBar(
              positionMs:
                  durationMs > 0 ? (_controller.value * durationMs).round() : 0,
              durationMs: durationMs,
              onScrub: _scrubTo,
              onSeek: _seekTo,
            ),
      ),
    );
  }
}
