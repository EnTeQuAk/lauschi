import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Fake [PlayerNotifier] for widget tests.
///
/// Returns the provided initial state from [build()] and exposes a
/// [setError] entry point so tests can simulate the player transitioning
/// into an error. All mutating methods from the real notifier are
/// overridden to no-ops, which is necessary because the real
/// [PlayerNotifier] has `late` fields that would throw on access.
///
/// Scope: currently only `content_unavailable_screen_test.dart` uses
/// this. It needs `setError` and the boolean `clearErrorCalled` to
/// verify the error-dialog callback. Anything beyond that is YAGNI —
/// add tracking fields here when a test actually reads them.
class FakePlayerNotifier extends PlayerNotifier {
  FakePlayerNotifier(this._initialState);

  final PlaybackState _initialState;

  /// Set by [clearError] so tests can verify the error-dialog callback
  /// actually invoked the notifier's clear-error path.
  bool clearErrorCalled = false;

  @override
  PlaybackState build() => _initialState;

  /// Push an error into the current state.
  ///
  /// Used by tests to simulate the player transitioning into an error
  /// state after the widget has already mounted, which triggers
  /// `ref.listen` callbacks that drive the error-dialog UI.
  void setError(PlayerError error) {
    state = state.copyWith(error: error);
  }

  @override
  void clearError() {
    clearErrorCalled = true;
    // `copyWith(error: null)` is the documented way to clear the error
    // field — the field is always-replaced, not sticky, so this works
    // even though it looks like a no-op.
    // ignore: avoid_redundant_argument_values
    state = state.copyWith(error: null);
  }

  // The remaining overrides below are no-op stubs. They exist to stop
  // the test accidentally hitting the real [PlayerNotifier]'s unset
  // `late` fields (which would crash). They do NOT track calls — no
  // test currently reads such tracking, so adding fields for it would
  // be dead code. When a test needs to assert a call happened, add a
  // counter here at that time.

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> togglePlay() async {}

  @override
  Future<void> playCard(String cardId) async {}

  @override
  Future<void> seek(int positionMs) async {}

  @override
  Future<void> nextTrack() async {}

  @override
  Future<void> prevTrack() async {}
}
