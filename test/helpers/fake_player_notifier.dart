import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/player/player_state.dart';

/// Fake [PlayerNotifier] for widget tests.
///
/// Returns the provided initial state from [build()] and tracks
/// method calls for assertion. All public methods are overridden
/// to prevent accidental access to the real notifier's late fields.
class FakePlayerNotifier extends PlayerNotifier {
  FakePlayerNotifier(this._initialState);

  final PlaybackState _initialState;
  bool clearErrorCalled = false;
  bool pauseCalled = false;
  bool resumeCalled = false;
  int togglePlayCount = 0;
  String? lastPlayedCardId;

  @override
  PlaybackState build() => _initialState;

  /// Simulate an error appearing (triggers ref.listen callbacks).
  void setError(PlayerError error) {
    state = state.copyWith(error: error);
  }

  @override
  void clearError() {
    clearErrorCalled = true;
    // ignore: avoid_redundant_argument_values, null clears error (always-replace)
    state = state.copyWith(error: null);
  }

  @override
  Future<void> pause() async => pauseCalled = true;

  @override
  Future<void> resume() async => resumeCalled = true;

  @override
  Future<void> togglePlay() async => togglePlayCount++;

  @override
  Future<void> playCard(String cardId) async => lastPlayedCardId = cardId;

  final seekCalls = <int>[];
  final nextTrackCalls = <void>[];
  final prevTrackCalls = <void>[];

  @override
  Future<void> seek(int positionMs) async => seekCalls.add(positionMs);

  @override
  Future<void> nextTrack() async => nextTrackCalls.add(null);

  @override
  Future<void> prevTrack() async => prevTrackCalls.add(null);
}
