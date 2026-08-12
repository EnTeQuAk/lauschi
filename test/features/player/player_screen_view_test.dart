import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/screens/player/screen.dart';

/// The player screen selects [playerScreenView] so it rebuilds only on
/// track / play-state changes, not the per-second position tick. The
/// record's value equality is what makes Riverpod's select skip the
/// rebuild, so this pins that position and duration are not part of it.
void main() {
  group('playerScreenView', () {
    const track = TrackInfo(uri: 'ard:item:1', name: 'Folge 7');

    test('is equal for two states differing only in position', () {
      const a = PlaybackState(
        track: track,
        isPlaying: true,
        positionMs: 5000,
        durationMs: 1800000,
      );
      const b = PlaybackState(
        track: track,
        isPlaying: true,
        positionMs: 6000, // one tick later
        durationMs: 1800000,
      );
      expect(
        playerScreenView(a),
        playerScreenView(b),
        reason: 'a position tick must not rebuild the whole player screen',
      );
    });

    test('differs when the track changes', () {
      const a = PlaybackState(track: track, isPlaying: true);
      const b = PlaybackState(
        track: TrackInfo(uri: 'ard:item:2', name: 'Folge 8'),
        isPlaying: true,
      );
      expect(playerScreenView(a), isNot(playerScreenView(b)));
    });

    test('differs when play or loading state changes', () {
      const base = PlaybackState(track: track);
      expect(
        playerScreenView(base),
        isNot(playerScreenView(base.copyWith(isPlaying: true))),
      );
      expect(
        playerScreenView(base),
        isNot(playerScreenView(base.copyWith(isLoading: true))),
      );
    });
  });
}
