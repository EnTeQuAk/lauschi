import 'dart:async' show unawaited;

import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_webview_bridge.dart';

const _tag = 'SpotifyPlayer';

/// Adapter that controls Spotify playback of one card through both the
/// local SDK and the Web API.
///
/// Commands fire the local SDK first (immediate audio effect, works
/// offline) then the Web API (reliable server-side confirmation).
/// The SDK call is fire-and-forget — we don't wait for it or fail
/// on it. The Web API call is awaited and errors propagate.
///
/// The bridge is shared by every Spotify card, so [stateStream] passes
/// on only the states of this card's context, see [SpotifyContextGate].
class SpotifyPlayer extends PlayerBackend {
  SpotifyPlayer(this._bridge, this._api, {required String contextUri})
    : _gate = SpotifyContextGate(contextUri);

  final SpotifyWebViewBridge _bridge;
  final SpotifyApi _api;
  final SpotifyContextGate _gate;

  // The bridge fills its getters before it emits a state, and the next
  // SDK message only arrives in a later event-loop task, so reading
  // them in the listener sees the values that belong to this state.
  @override
  Stream<PlaybackState> get stateStream =>
      _bridge.stateStream
          .map(
            (state) => _gate.accept(
              state,
              contextUri: _bridge.contextUri,
              isLastTrack: !hasNextTrack,
            ),
          )
          .where((state) => state != null)
          .cast<PlaybackState>();

  @override
  int get currentPositionMs => _bridge.estimatedPositionMs;

  /// The card's tracks, in order, once [loadTracks] has fetched them.
  List<SpotifyTrack> _tracks = const [];

  /// Index of the playing track in [_tracks], or -1 when unknown.
  int get _trackIndex {
    final uri = _bridge.currentState.track?.uri;
    return uri == null ? -1 : _tracks.indexWhere((t) => t.uri == uri);
  }

  /// Fetch the card's track list. The SDK's own track window only holds
  /// the tracks around the current one, so it can't say where in a
  /// longer album playback is. Without the list (fetch failed), the
  /// player falls back to the SDK's window.
  Future<void> loadTracks(String providerUri) async {
    final id = ProviderType.extractId(providerUri);
    if (id == null) return;
    try {
      if (providerUri.contains(':playlist:')) {
        _tracks = (await _api.getPlaylist(id))?.tracks ?? const [];
      } else {
        _tracks = await _api.getAlbumTracks(id);
      }
    } on Exception catch (e) {
      Log.warn(_tag, 'Track list unavailable', data: {'error': '$e'});
    }
  }

  @override
  int get currentTrackNumber {
    final index = _trackIndex;
    return index >= 0 ? index + 1 : _bridge.trackNumber;
  }

  @override
  bool get hasNextTrack {
    final index = _trackIndex;
    return index >= 0
        ? index < _tracks.length - 1
        : _bridge.nextTracksCount > 0;
  }

  @override
  int get elapsedMs =>
      _trackIndex >= 0
          ? elapsedAcrossTracks(
            [for (final t in _tracks) t.durationMs],
            trackNumber: currentTrackNumber,
            positionMs: currentPositionMs,
          )
          : 0;

  @override
  int get contentDurationMs =>
      _trackIndex >= 0 ? _tracks.fold(0, (sum, t) => sum + t.durationMs) : 0;

  @override
  Future<void> pause() async {
    Log.info(_tag, 'pause');
    // SDK: immediate local audio pause (fire-and-forget).
    unawaited(_bridge.pause());
    // Web API: reliable server-side pause.
    await _api.pause();
  }

  @override
  Future<void> resume() async {
    Log.info(_tag, 'resume');
    final deviceId = _bridge.deviceId;
    if (deviceId == null) {
      throw const SpotifyDeviceNotFoundException('No active device');
    }
    // SDK: immediate local audio resume (fire-and-forget).
    unawaited(_bridge.resume());
    // Web API: reliable server-side resume.
    await _api.resume(deviceId: deviceId);
  }

  @override
  Future<void> seek(int positionMs) async {
    Log.debug(_tag, 'seek', data: {'positionMs': '$positionMs'});
    _gate.expectJump();
    // Seek goes through Web API only. Firing both causes competing
    // state_changed events from the SDK that make the progress bar jump.
    await _api.seek(positionMs);
  }

  @override
  Future<void> nextTrack() async {
    Log.info(_tag, 'nextTrack');
    _gate.expectJump();
    // Web API only. Firing both SDK and API causes a double-skip:
    // each independently advances the track, resulting in two
    // Track changed events and jumping two tracks per click.
    // Same reasoning as seek().
    await _api.nextTrack();
  }

  @override
  Future<void> prevTrack() async {
    Log.info(_tag, 'prevTrack');
    _gate.expectJump();
    // Web API only. See nextTrack() comment.
    await _api.previousTrack();
  }

  @override
  Future<void> stop() async {
    unawaited(_bridge.pause());
    // Best-effort: the Web API pause can fail when the WebView has been
    // killed by iOS (device gone → 404/400) or Spotify is having a bad
    // day (502). We're tearing down this backend anyway, so swallow it.
    try {
      await _api.pause();
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'stop: API pause failed (expected if device gone)',
        data: {'error': '$e'},
      );
    }
  }

  @override
  Future<void> dispose() async {
    // Bridge lifecycle is managed by SpotifySession, not here.
    // SpotifyPlayer is created per-play session; the bridge outlives it.
  }
}

/// Decides which bridge states belong to one card's playback, and when
/// that playback has reached the end of the card.
///
/// The bridge keeps reporting the previous card for a moment after a
/// switch. In the field, the old episode's last "paused near the end"
/// state arrived after the new card's play command and marked the new
/// card heard. So a card ignores every state from another context until
/// its own context has started.
///
/// Spotify has no "album ended" event. It leaves the last track without
/// being asked: it either wraps to the start of the album and pauses, or
/// moves on to another context (autoplay). Both count as the end, and
/// both are recognised only right after a state on the last track, so a
/// kid's own seek or skip ([expectJump]) never looks like one.
class SpotifyContextGate {
  SpotifyContextGate(this.contextUri);

  /// The card's album or playlist, e.g. `spotify:album:…`.
  final String contextUri;

  bool _started = false;
  _GateState? _last;

  /// The kid asked for a seek or a track skip. Forget the last state, so
  /// the jump that follows is not taken for the end.
  void expectJump() => _last = null;

  /// The state to pass on for a bridge [state] that the SDK reported with
  /// [contextUri] and [isLastTrack], or null to drop it.
  ///
  /// A missing context counts as this card's: the SDK only omits it in
  /// rare cases, and dropping those states could leave a card stuck in
  /// loading.
  PlaybackState? accept(
    PlaybackState state, {
    required String? contextUri,
    required bool isLastTrack,
  }) {
    final last = _last;
    final isOwn = contextUri == null || contextUri == this.contextUri;
    if (!isOwn) {
      if (!_started || last == null || !last.isLastTrack) return null;
      // Autoplay moved on after the last track. Keep showing this card.
      _last = null;
      return last.state.copyWith(
        isPlaying: false,
        isFinished: true,
        error: last.state.error,
      );
    }

    _started = true;
    final wrapped =
        last != null &&
        last.isLastTrack &&
        last.state.positionMs > 0 &&
        !state.isPlaying &&
        state.positionMs == 0;
    _last = _GateState(state, isLastTrack: isLastTrack);
    return wrapped
        ? state.copyWith(isFinished: true, error: state.error)
        : state;
  }
}

class _GateState {
  _GateState(this.state, {required this.isLastTrack});

  final PlaybackState state;
  final bool isLastTrack;
}
