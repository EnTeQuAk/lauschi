import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Fake [PlayerNotifier] for widget tests.
///
/// Returns the provided initial state from [build()] and tracks
/// method calls for assertion.
class FakePlayerNotifier extends PlayerNotifier {
  FakePlayerNotifier(this._initialState);

  final PlaybackState _initialState;
  bool clearErrorCalled = false;

  @override
  PlaybackState build() => _initialState;

  @override
  void clearError() {
    clearErrorCalled = true;
    // Explicitly null the error (always-replace semantics).
    // ignore: avoid_redundant_argument_values
    state = state.copyWith(error: null);
  }
}
