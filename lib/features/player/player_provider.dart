import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/apple_music_backend.dart';
import 'package:lauschi/features/player/apple_music_drm_backend.dart';
import 'package:lauschi/features/player/apple_music_native_backend.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_player.dart';
import 'package:lauschi/features/player/spotify_webview_bridge.dart';
import 'package:lauschi/features/player/stream_player.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'player_provider.g.dart';

const _tag = 'PlayerProvider';

/// Threshold for "near end of track" detection, shared across all completion
/// paths (transition detection, pause fallback, periodic timer).
const _completionThresholdMs = 5000;

/// Holds the [MediaSessionHandler] initialized in main().
/// Must be overridden before use.
@Riverpod(keepAlive: true)
MediaSessionHandler mediaSessionHandler(Ref ref) {
  throw StateError(
    'mediaSessionHandlerProvider must be overridden with an '
    'initialized MediaSessionHandler',
  );
}

// ---------------------------------------------------------------------------
// _ActiveBackend — bundles a backend with its state subscription
// ---------------------------------------------------------------------------

/// Pairs a [PlayerBackend] with its state subscription so they are always
/// created and torn down together. Prevents dangling subscriptions from
/// a disposed backend writing stale state.
class _ActiveBackend {
  _ActiveBackend(this.backend, [this._subscription]);

  final PlayerBackend backend;
  final StreamSubscription<PlaybackState>? _subscription;

  /// Full teardown: cancel the state subscription, stop playback, and
  /// release the backend's resources. See [teardownBackend].
  Future<void> dispose() => teardownBackend(backend, _subscription);
}

/// Tear an active backend fully down: cancel its state subscription,
/// stop playback, then release its resources.
///
/// Backends are created fresh per play and never reused, so a
/// torn-down backend must be disposed, not just stopped. Stopping
/// alone leaks the native player (StreamPlayer) and the shared-stream
/// subscription (Apple Music) — and the leaked Apple Music subscription
/// can hijack playback by advancing a stale album on a `trackEnded`
/// event. dispose() alone is not enough either: SpotifyPlayer.dispose
/// and AppleMusicBackend.dispose don't halt audio, so stop() must run
/// first or switching providers leaves the old backend still playing.
Future<void> teardownBackend(
  PlayerBackend backend,
  StreamSubscription<PlaybackState>? subscription,
) async {
  await subscription?.cancel();
  await backend.stop();
  await backend.dispose();
}

// ---------------------------------------------------------------------------
// _LastKnownPlaybackState — tracks previous state for transition detection
// ---------------------------------------------------------------------------

/// Captures playback state from the previous tick to detect completion
/// via state transitions rather than just position checks.
///
/// This solves the race condition with auto-advancing players (Spotify)
/// where by the time we check isAlbumComplete, we're already on the next
/// track and hasNextTrack/position reflect the new track, not the one
/// that just finished.
class _LastKnownPlaybackState {
  _LastKnownPlaybackState({
    required this.positionMs,
    required this.durationMs,
    required this.hasNextTrack,
    required this.trackUri,
  });

  final int positionMs;
  final int durationMs;
  final bool hasNextTrack;
  final String? trackUri;

  bool isNearEnd({int thresholdMs = _completionThresholdMs}) =>
      durationMs > 0 && positionMs > durationMs - thresholdMs;
}

// ---------------------------------------------------------------------------
// PlayerNotifier
// ---------------------------------------------------------------------------

/// Manages playback state and coordinates backends, position saving,
/// and media session.
///
/// Spotify integration goes through [SpotifySession]. This notifier
/// has no direct auth wiring, token management, or bridge lifecycle
/// concerns. It watches the session state and reacts to auth changes
/// (e.g. stops Spotify playback on logout).
@Riverpod(keepAlive: true)
class PlayerNotifier extends _$PlayerNotifier {
  late MediaSessionHandler _mediaSession;

  /// Spotify session. Null when Spotify is disabled.
  SpotifySession? _session;

  /// Shortcuts into the session for playback code.
  SpotifyWebViewBridge? get _bridge => _session?.bridge;
  SpotifyApi? get _api => _session?.api;

  /// Permanent subscription to the Spotify bridge state stream.
  /// Routes playback events only when Spotify is the active backend;
  /// always accepts device metadata (isReady).
  ///
  /// This is intentionally asymmetric with StreamPlayer's per-play
  /// subscription (bundled in _ActiveBackend). The bridge is long-lived
  /// and reports device readiness even when no card is playing;
  /// StreamPlayer is created per-play and dies with the backend.
  StreamSubscription<PlaybackState>? _bridgeSub;

  /// The currently active backend + its subscription, or null.
  _ActiveBackend? _active;

  Timer? _positionSaveTimer;

  /// Monotonically increasing generation counter. Each [playCard] call
  /// increments this. Stale async continuations compare their captured
  /// generation and bail out if superseded.
  int _playGen = 0;

  /// Whether there is a track before the current one (for prev button).
  bool get hasPrevTrack => (_active?.backend.currentTrackNumber ?? 0) > 1;

  /// Whether there is a track after the current one (for next button).
  bool get hasNextTrack => _active?.backend.hasNextTrack ?? false;

  // -- Timing constants --
  static const _deviceRegistrationDelay = Duration(milliseconds: 500);
  static const _positionSaveInterval = Duration(seconds: 10);

  // -- Position tracking state --
  int _playTimeMs = 0;
  final Stopwatch _playStopwatch = Stopwatch();

  /// Tracks the last known playback state to detect track completion
  /// via transitions (needed for auto-advancing players like Spotify).
  /// Captures position, duration, and hasNextTrack from previous state.
  _LastKnownPlaybackState? _lastPlaybackState;

  /// Guards against repeated completion triggers from the periodic timer.
  /// Set to true when completion is handled; reset in playCard().
  bool _completionHandledForSession = false;

  @override
  PlaybackState build() {
    _mediaSession = ref.watch(mediaSessionHandlerProvider);

    // Wire system media button callbacks.
    _mediaSession.onPlay = resume;
    _mediaSession.onPause = () => unawaited(pause());
    _mediaSession.onSkipNext = () => unawaited(nextTrack());
    _mediaSession.onSkipPrev = () => unawaited(prevTrack());
    _mediaSession.onSeek = (pos) => unawaited(seek(pos.inMilliseconds));

    if (FeatureFlags.enableSpotify) {
      // Read (not watch) the session notifier. We don't want token
      // refreshes to rebuild this provider and wipe playback state.
      // Auth loss is handled via ref.listen below.
      _session = ref.read(spotifySessionProvider.notifier);

      // Subscribe to bridge state stream (once per provider lifetime).
      _bridgeSub ??= _session!.bridge.stateStream.listen(_onBridgeEvent);

      // React to auth loss without triggering a full rebuild.
      // ref.listen fires the callback on state changes; it does NOT
      // cause build() to re-run (unlike ref.watch).
      ref.listen<SpotifySessionState>(spotifySessionProvider, (prev, next) {
        if (next is SpotifyUnauthenticated ||
            next is SpotifyReauthRequired ||
            next is SpotifyError) {
          _onSpotifyDisconnected();
        }
      });
    }

    ref.onDispose(() {
      unawaited(_bridgeSub?.cancel());
      _bridgeSub = null;
      unawaited(_active?.dispose());
      _positionSaveTimer?.cancel();
    });

    return const PlaybackState();
  }

  void _onBridgeEvent(PlaybackState bridgeState) {
    final isSpotifyActive = _active?.backend is SpotifyPlayer;

    if (isSpotifyActive) {
      // Detect WebView recovery: bridge went not-ready → ready while
      // a card was actively playing. This happens after iOS kills the
      // web content process and the page reloads. The SDK is healthy
      // again but has no playback context, so replay the active card.
      //
      // Guard with _recovering to prevent cascading replays. The bridge
      // can emit multiple `ready` events during a single reload cycle,
      // and each playCard triggers more bridge events. Without this,
      // one process death causes 3-4 redundant play commands.
      final wasNotReady = !state.isReady;
      final isNowReady = bridgeState.isReady;
      final cardId = state.activeCardId;
      if (wasNotReady && isNowReady && cardId != null) {
        Log.info(
          _tag,
          'Bridge recovered while card active, replaying',
          data: {'cardId': cardId},
        );
        // Update isReady BEFORE calling playCard. The early return
        // below skips the normal state merge, so without this,
        // state.isReady stays false and the next bridge event
        // (Track changed) sees wasNotReady=true again, triggering
        // another recovery cascade.
        state = state.copyWith(isReady: true);
        unawaited(playCard(cardId, forceReplay: true));
        return;
      }

      // Single write: merge isReady + playback fields.
      final wasPlaying = state.isPlaying;
      state = mergeSpotifyBridgeState(state, bridgeState);
      _onPlaybackStateChange(state, wasPlaying: wasPlaying);
    } else {
      final updated = applyIdleBridgeReadiness(
        state,
        bridgeReady: bridgeState.isReady,
        hasActiveBackend: _active != null,
      );
      if (updated != null) state = updated;
    }
  }

  /// Handle Spotify auth loss. Stops active Spotify playback and resets
  /// player state. Bridge teardown is handled by SpotifySession.
  void _onSpotifyDisconnected() {
    if (_active?.backend is! SpotifyPlayer) return;

    Log.info(_tag, 'Spotify disconnected, stopping playback');

    // Don't cancel _bridgeSub here. The bridge stream stays open across
    // tearDown/init cycles (that's the whole point of tearDown vs dispose).
    // If we cancel, the ??= guard in build() prevents re-subscription on
    // re-login since PlayerNotifier is keepAlive and build() won't re-run.
    // _onBridgeEvent already gates playback events on _active being a
    // SpotifyPlayer, so stale events from tearDown are harmless.
    assert(
      _bridgeSub != null,
      '_bridgeSub must stay alive across Spotify disconnect/reconnect. '
      'Only ref.onDispose should cancel it.',
    );

    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _playTimeMs = 0;
    _playStopwatch
      ..stop()
      ..reset();

    unawaited(_active?.dispose());
    _active = null;
    // Carry an error, not a blank state: the player screen only pops on
    // an error clearing, so resetting to const PlaybackState() would
    // strand the kid on an empty, silent player with no explanation.
    state = spotifyDisconnectedState;
  }

  // ─── Public API ──────────────────────────────────────────────────────

  /// Pause playback (idempotent).
  ///
  /// Handled separately from [_backendCommand] because a failed pause
  /// means the audio already stopped (device gone). Replaying the card
  /// in response would restart audio, which is the opposite of what
  /// the user wanted.
  Future<void> pause() async {
    Log.info(_tag, 'pause');

    try {
      await _active?.backend.pause();
    } on Exception catch (e) {
      Log.debug(
        _tag,
        'pause failed (device likely gone)',
        data: {'error': '$e'},
      );
    }
  }

  /// Stop playback and tear down the backend. Resets state to idle.
  ///
  /// Unlike [pause], this releases backend resources (audio session,
  /// media player). Used when playback should fully end, not just suspend.
  Future<void> stopCard() async {
    Log.info(_tag, 'stopCard');
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _playTimeMs = 0;
    _playStopwatch
      ..stop()
      ..reset();
    _lastPlaybackState = null;
    _completionHandledForSession = false;

    await _active?.dispose();
    _active = null;
    state = const PlaybackState();
  }

  /// Resume playback (idempotent).
  Future<void> resume() async {
    Log.info(_tag, 'resume');
    await _backendCommand('resume', (b) => b.resume());
  }

  /// Toggle play/pause.
  Future<void> togglePlay() async {
    if (state.isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  Future<void> nextTrack() async {
    await _backendCommand('next', (b) => b.nextTrack());
  }

  Future<void> prevTrack() async {
    await _backendCommand('prev', (b) => b.prevTrack());
  }

  Future<void> seek(int positionMs) async {
    await _backendCommand('seek', (b) => b.seek(positionMs));
  }

  void clearError() {
    // ignore: avoid_redundant_argument_values, null clears error
    state = state.copyWith(error: null);
  }

  /// Resume playback for a card, restoring saved position.
  ///
  /// [forceReplay] bypasses the already-playing guard for internal
  /// recovery replays (WebView process death, Spotify device lost),
  /// which re-invoke playCard to rebuild a lost SDK context while
  /// [PlaybackState.isPlaying] is still true. User taps leave it false.
  Future<void> playCard(String cardId, {bool forceReplay = false}) async {
    // Re-tapping the already-playing card must not restart it: tearing
    // the backend down mid-story cuts the audio and resumes from the
    // last saved position, audibly jumping backwards. Kids tap the
    // glowing card (and re-present NFC figures) expecting nothing
    // worse than the player opening. Recovery replays pass forceReplay.
    if (shouldIgnoreRepeatPlay(
      cardId: cardId,
      activeCardId: state.activeCardId,
      isPlaying: state.isPlaying,
      forceReplay: forceReplay,
    )) {
      Log.info(
        _tag,
        'playCard ignored, already playing',
        data: {
          'cardId': cardId,
        },
      );
      return;
    }
    final gen = ++_playGen;
    Log.info(
      _tag,
      'playCard gen=$gen',
      data: {'cardId': cardId, 'previous': state.activeCardId ?? 'none'},
    );

    // Fold the running stopwatch into the old card's play time and
    // capture it before the reset below zeroes it. The save-on-switch
    // guard needs the OLD card's play time; reading _playTimeMs there
    // (post-reset) is always 0, so that save never ran and up to ~10s
    // of the old episode's progress was lost since the last periodic
    // tick.
    _updatePlayTime();
    final oldPlayTimeMs = _playTimeMs;

    // Cancel pending timers and reset tracking.

    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _playTimeMs = 0;
    _playStopwatch
      ..stop()
      ..reset();
    _lastPlaybackState = null;
    _completionHandledForSession = false;

    final card = await ref.read(tileItemRepositoryProvider).getById(cardId);
    if (card == null) {
      Log.error(_tag, 'Card not found', data: {'cardId': cardId});
      return;
    }
    if (_playGen != gen) {
      Log.debug(_tag, 'playCard gen=$gen superseded (now $_playGen), bailing');
      return;
    }

    // Block playback only for items explicitly marked unavailable (runtime
    // detection). We do NOT block on availableUntil alone because ARD's
    // endDate is an editorial broadcast window, not content removal.
    // Audio URLs remain accessible on CDN well past endDate.
    if (card.markedUnavailable != null) {
      state = state.copyWith(
        error: PlayerError.contentUnavailable,
      );
      return;
    }

    // Capture old card values before overwriting state.
    final oldCardId = state.activeCardId;
    final oldTrack = state.track;
    final oldPos = _active?.backend.currentPositionMs ?? state.positionMs;

    // Set active card state with placeholder track info from DB so the
    // player screen shows cover art and title immediately. isLoading
    // signals the UI to show a loading overlay on top.
    state = state.copyWith(
      activeCardId: cardId,
      activeContextUri: card.providerUri,
      activeGroupId: card.groupId,
      isLoading: true,
      track: TrackInfo(
        uri: card.providerUri,
        name: card.customTitle ?? card.title,
        artworkUrl: card.coverUrl,
      ),
    );

    // Save position from the old backend before tearing it down.
    if (shouldSavePosition(playTimeMs: oldPlayTimeMs) &&
        oldCardId != null &&
        oldTrack != null) {
      Log.info(
        _tag,
        'Saving position on card switch',
        data: {
          'oldCardId': oldCardId,
          'positionMs': oldPos,
          'playTimeMs': oldPlayTimeMs,
        },
      );
      unawaited(_savePosition(oldCardId, oldTrack, oldPos));
    }

    // CD-player model: each tile has at most one active episode.
    // Clear stale positions from other episodes in this tile so the
    // "Weiter" badge always points at the episode we're about to play.
    if (card.groupId != null) {
      unawaited(
        ref
            .read(tileItemRepositoryProvider)
            .clearPositions(card.groupId!, excludeItemId: cardId),
      );
    }

    // Pause Spotify bridge if it's playing (avoid dual audio).
    final bridge = _bridge;
    if (bridge != null && bridge.currentState.isPlaying) {
      await bridge.pause();
    }

    // Tear down previous backend. Capture and null _active synchronously
    // before awaiting stop(), so a concurrent playCard() doesn't see a
    // stale reference. See #211.
    final previousBackend = _active;
    _active = null;
    if (previousBackend != null) {
      Log.debug(
        _tag,
        'Tearing down ${previousBackend.backend.runtimeType} gen=$gen',
      );
      await previousBackend.dispose();
    }
    if (_playGen != gen) {
      Log.debug(_tag, 'playCard gen=$gen superseded during teardown');
      return;
    }

    // Create and activate new backend.
    try {
      switch (ProviderType.fromString(card.provider)) {
        case ProviderType.spotify:
          await _startSpotify(card, gen);
        case ProviderType.ardAudiothek:
          await _startDirect(card, gen);
        case ProviderType.appleMusic:
          await _startAppleMusic(card, gen);
        case ProviderType.tidal:
          Log.error(
            _tag,
            'Provider not yet supported',
            data: {'provider': card.provider},
          );
          state = state.copyWith(
            error: PlayerError.playbackFailed,
          );
      }
    } on Exception catch (e) {
      if (_playGen != gen) return;
      Log.error(_tag, 'Play failed', exception: e);
      state = state.copyWith(
        error: PlayerError.playbackFailed,
        isLoading: false,
      );
    }
    // Note: isLoading is NOT cleared here in a finally block.
    // For Apple Music, the EventChannel listener clears it when isPlaying
    // becomes true (the DRM pipeline runs asynchronously after play() returns).
    // For Spotify/ARD, play() blocks until audio starts, so isLoading is
    // cleared by the state listener receiving the first playing event.
  }

  // ─── Backend command dispatch ────────────────────────────────────────

  /// Run a playback command on the active backend. If the Spotify device
  /// is gone, replay the active card instead of retrying the individual
  /// command. A fresh SDK (after page reload or reconnect) has no album
  /// context, so resume/next/prev/seek can never work without a `play`
  /// command first. Replaying the card provides that context.
  Future<void> _backendCommand(
    String name,
    Future<void> Function(PlayerBackend) command,
  ) async {
    final backend = _active?.backend;
    if (backend == null) {
      Log.debug(_tag, '$name ignored — no active backend');
      return;
    }

    try {
      await command(backend);
    } on SpotifyDeviceNotFoundException {
      final cardId = state.activeCardId;
      if (cardId != null) {
        Log.info(_tag, '$name: device lost, replaying card');
        await playCard(cardId, forceReplay: true);
      } else {
        state = state.copyWith(error: PlayerError.spotifyConnectionLost);
      }
    } on Exception catch (e) {
      Log.error(_tag, '$name failed', exception: e);
      state = state.copyWith(error: PlayerError.playbackCommandFailed);
    }
  }

  // ─── Spotify startup ────────────────────────────────────────────────

  Future<void> _startSpotify(db.TileItem card, int gen) async {
    final session = _session;
    final bridge = _bridge;
    final api = _api;
    if (session == null || bridge == null || api == null) {
      state = state.copyWith(error: PlayerError.spotifyNotConnected);
      return;
    }

    Log.info(
      _tag,
      'Starting Spotify backend gen=$gen',
      data: {'uri': card.providerUri},
    );

    // Get a valid token through the session's single entry point.
    final token = await session.validToken();
    if (_playGen != gen) return;
    if (token == null) {
      state = state.copyWith(error: PlayerError.spotifyAuthExpired);
      return;
    }

    final deviceId = await _ensureDevice(bridge, gen);
    if (deviceId == null || _playGen != gen) return;

    // SpotifyPlayer routes state through _onBridgeEvent, so no
    // per-backend subscription needed.
    _active = _ActiveBackend(SpotifyPlayer(bridge, api));

    await _playOnDevice(api, bridge, card, deviceId, gen);
  }

  /// Get a valid device ID, reconnecting if needed. Returns null on failure.
  Future<String?> _ensureDevice(SpotifyWebViewBridge bridge, int gen) async {
    final currentDeviceId = bridge.deviceId;
    if (currentDeviceId != null) return currentDeviceId;

    // Wait first — the SDK may still be initializing after a fresh app
    // launch (typically 3-5s). Reconnecting during initial load is
    // counterproductive (fires JS into a half-loaded page or triggers
    // a reload that restarts the load).
    Log.info(_tag, 'No device ID — waiting for bridge');
    var deviceId = await bridge.waitForDevice(
      timeout: const Duration(seconds: 5),
    );
    if (_playGen != gen) return null;

    // Still nothing after waiting. Now try reconnecting (WebView process
    // may have died from low memory, or SDK connection dropped).
    if (deviceId == null) {
      Log.warn(_tag, 'No device after wait — attempting reconnect');
      await bridge.reconnect();
      // After a cold reload (process death), the WebView needs to:
      // 1. Load player.html  2. Parse Spotify SDK JS  3. Init + connect
      // This takes longer than the initial 5s wait. Give it 15s.
      deviceId = await bridge.waitForDevice(
        timeout: const Duration(seconds: 15),
      );
      if (_playGen != gen) return null;
    }

    if (deviceId == null) {
      Log.warn(_tag, 'No device ID after reconnect');
      state = state.copyWith(
        error: PlayerError.spotifyNotConnected,
      );
      return null;
    }

    // Brief delay for Spotify's servers to register the new device.
    await Future<void>.delayed(_deviceRegistrationDelay);
    if (_playGen != gen) return null;
    return deviceId;
  }

  /// Send play command to Spotify, with one reconnect retry on 404.
  Future<void> _playOnDevice(
    SpotifyApi api,
    SpotifyWebViewBridge bridge,
    db.TileItem card,
    String deviceId,
    int gen,
  ) async {
    Log.info(
      _tag,
      'Playing card',
      data: {
        'uri': card.providerUri,
        'provider': card.provider,
        'resumeTrack': card.lastTrackUri ?? 'none',
        'resumeMs': '${card.lastPositionMs}',
      },
    );

    try {
      await _sendPlayCommand(api, card.providerUri, deviceId, card);
      if (_playGen != gen) return;
    } on SpotifyDeviceNotFoundException {
      if (_playGen != gen) return;
      Log.warn(_tag, 'Device not found — reconnecting');
      await bridge.reconnect();
      final newDeviceId = await bridge.waitForDevice();
      if (_playGen != gen) return;
      if (newDeviceId == null) {
        Log.warn(_tag, 'No device ID after reconnect');
        state = state.copyWith(
          error: PlayerError.spotifyConnectionLost,
        );
        return;
      }
      await Future<void>.delayed(_deviceRegistrationDelay);
      if (_playGen != gen) return;

      try {
        await _sendPlayCommand(api, card.providerUri, newDeviceId, card);
        if (_playGen != gen) return;
      } on SpotifyDeviceNotFoundException {
        if (_playGen != gen) return;
        Log.warn(_tag, 'Device still not found after reconnect');
        state = state.copyWith(
          error: PlayerError.spotifyConnectionLost,
        );
      }
    }
  }

  Future<void> _sendPlayCommand(
    SpotifyApi api,
    String spotifyUri,
    String deviceId,
    db.TileItem card,
  ) async {
    if (card.lastTrackUri != null && card.lastPositionMs > 0) {
      await api.play(
        spotifyUri,
        deviceId: deviceId,
        offsetUri: card.lastTrackUri,
        positionMs: card.lastPositionMs,
      );
    } else {
      await api.play(spotifyUri, deviceId: deviceId);
    }
  }

  // ─── StreamPlayer startup ──────────────────────────────────────────

  Future<void> _startDirect(db.TileItem card, int gen) async {
    Log.info(
      _tag,
      'Starting StreamPlayer gen=$gen',
      data: {'cardId': card.id, 'provider': card.provider},
    );
    if (card.audioUrl == null || card.audioUrl!.isEmpty) {
      Log.error(_tag, 'No audio URL', data: {'cardId': card.id});
      state = state.copyWith(
        error: PlayerError.noAudioUrl,
      );
      return;
    }

    final player = StreamPlayer();
    _active = _ActiveBackend(
      player,
      player.stateStream.listen((directState) {
        if (_playGen != gen) return;
        final wasPlaying = state.isPlaying;
        state = state.copyWith(
          isPlaying: directState.isPlaying,
          isReady: directState.isReady,
          // Clear loading overlay once audio starts or errors.
          isLoading:
              state.isLoading &&
              !directState.isPlaying &&
              directState.error == null,
          track: directState.track,
          positionMs: directState.positionMs,
          durationMs: directState.durationMs,
          error: directState.error ?? state.error,
        );
        _onPlaybackStateChange(state, wasPlaying: wasPlaying);
      }),
    );

    final trackInfo = TrackInfo(
      uri: card.providerUri,
      name: card.customTitle ?? card.title,
      artworkUrl: card.coverUrl,
    );

    Log.info(
      _tag,
      'Playing card (direct)',
      data: {
        'cardId': card.id,
        'provider': card.provider,
        'resumeMs': '${card.lastPositionMs}',
      },
    );

    // StreamPlayer.play() returns once setup (setUrl + seek + first play
    // request) is done. Subsequent playback progress and errors arrive
    // via the state stream listener registered above.
    await player.play(
      audioUrl: card.audioUrl!,
      trackInfo: trackInfo,
      positionMs: card.lastPositionMs,
    );
  }

  // ─── Apple Music startup ──────────────────────────────────────────

  Future<void> _startAppleMusic(db.TileItem card, int gen) async {
    final amSession = ref.read(appleMusicSessionProvider.notifier);

    Log.info(
      _tag,
      'Starting Apple Music gen=$gen',
      data: {'card': card.title},
    );

    final albumId = ProviderType.extractId(card.providerUri) ?? '';

    final trackInfo = TrackInfo(
      uri: card.providerUri,
      name: card.title,
      artworkUrl: card.coverUrl,
    );

    final amState = ref.read(appleMusicSessionProvider);
    final auth = amState is AppleMusicAuthenticated ? amState : null;
    if (auth == null) {
      Log.warn(_tag, 'Apple Music not authenticated');
      state = state.copyWith(error: PlayerError.appleMusicAuthExpired);
      return;
    }

    // iOS: native MusicKit (ApplicationMusicPlayer). No stream resolution,
    // no DRM plumbing. MusicKit handles everything internally.
    // Android: ExoPlayer + Widevine DRM via webPlayback API.
    final AppleMusicBackend player;
    if (Platform.isIOS) {
      player = AppleMusicNativeBackend(
        api: amSession.api,
        musicKit: amSession.musicKit,
      );
    } else {
      player = AppleMusicDrmBackend(
        streamResolver: amSession.streamResolver,
        api: amSession.api,
        musicKit: amSession.musicKit,
        developerToken: auth.developerToken,
        musicUserToken: auth.musicUserToken,
      );
    }

    if (_playGen != gen) return;

    _active = _ActiveBackend(
      player,
      player.stateStream.listen((amState) {
        if (_playGen != gen) return;
        final wasPlaying = state.isPlaying;
        state = state.copyWith(
          isPlaying: amState.isPlaying,
          isReady: amState.isReady,
          isLoading:
              state.isLoading && !amState.isPlaying && amState.error == null,
          track: amState.track ?? state.track,
          positionMs: amState.positionMs,
          durationMs: amState.durationMs,
          error: amState.error ?? state.error,
        );
        _onPlaybackStateChange(state, wasPlaying: wasPlaying);
      }),
    );

    // Don't set isPlaying: true here. The EventChannel will push the
    // confirmed playing state from native player. Setting it prematurely
    // causes a brief "playing" flash if play() fails.
    state = state.copyWith(
      isReady: true,
      isLoading: true,
      track: trackInfo,
    );

    // Resume from saved track position. lastTrackNumber is 1-based in DB;
    // play() expects 0-based trackIndex.
    final savedTrackIndex =
        card.lastTrackNumber > 0 ? card.lastTrackNumber - 1 : 0;

    await player.play(
      albumId: albumId,
      trackInfo: trackInfo,
      trackIndex: savedTrackIndex,
      positionMs: card.lastPositionMs,
    );
  }

  // ─── Playback state change handling ─────────────────────────────────

  void _onPlaybackStateChange(
    PlaybackState newState, {
    required bool wasPlaying,
  }) {
    // No active backend → no side effects.
    if (_active == null) return;

    // Log play/pause transitions (not every position tick).
    if (newState.isPlaying != wasPlaying) {
      Log.debug(
        _tag,
        newState.isPlaying ? 'State: playing' : 'State: paused',
        data: {
          'cardId': state.activeCardId ?? '',
          'positionMs': '${newState.positionMs}',
          'durationMs': '${newState.durationMs}',
        },
      );
    }

    // #215: Log wakelock failures instead of silently swallowing.
    unawaited(
      WakelockPlus.toggle(enable: newState.isPlaying).catchError((Object e) {
        Log.warn(_tag, 'Wakelock toggle failed', data: {'error': '$e'});
      }),
    );
    // On iOS, MusicKit's ApplicationMusicPlayer auto-manages the Now Playing
    // session (lock screen controls, Control Center, AirPlay). Updating
    // audio_service would fight it. Let MusicKit own the media session.
    final isIosNativeMusicKit =
        Platform.isIOS && _active?.backend is AppleMusicNativeBackend;
    if (!isIosNativeMusicKit) {
      _mediaSession.updateFromAppState(
        state,
        hasNextTrack: _active?.backend.hasNextTrack ?? false,
      );
    }

    // ─── Album completion detection ───────────────────────────────────
    // Three paths can detect completion (transition, pause fallback,
    // periodic timer). The _completionHandledForSession guard prevents
    // duplicate triggers across all of them.
    final cardId = state.activeCardId;
    final groupId = state.activeGroupId;

    // Path 1: Detect completion via state transition. Handles the
    // auto-advance race where Spotify moves to the next track before
    // we can check the position of the track that just finished.
    if (!_completionHandledForSession) {
      final wasCompletedViaTransition = _detectCompletionViaTransition(
        newState.track,
      );
      if (wasCompletedViaTransition && cardId != null) {
        _completionHandledForSession = true;
        unawaited(_onAlbumCompleted(cardId, groupId));
      }
    }

    // ─── Standard play/pause handling ─────────────────────────────────
    if (newState.isPlaying) {
      _startPositionSave();
    } else {
      _stopPositionSave();

      // Capture values now — by the time the async save/mark-heard runs,
      // a new card may own state and these fields would be wrong.
      final track = state.track;
      final posMs = _active?.backend.currentPositionMs ?? newState.positionMs;

      if (shouldSavePositionInSession(
            playTimeMs: _playTimeMs,
            completionHandled: _completionHandledForSession,
          ) &&
          cardId != null &&
          track != null) {
        unawaited(_savePosition(cardId, track, posMs));
      }

      // Path 2: Paused on last track, within threshold of end.
      // Catches cases where transition detection missed it.
      if (!_completionHandledForSession &&
          isAlbumComplete(
            hasNextTrack: _active?.backend.hasNextTrack ?? false,
            positionMs: posMs,
            durationMs: newState.durationMs,
          )) {
        _completionHandledForSession = true;
        unawaited(_onAlbumCompleted(cardId, groupId));
      }
    }

    // ─── Update last known state for next transition detection ─────────
    _lastPlaybackState = _LastKnownPlaybackState(
      positionMs: _active?.backend.currentPositionMs ?? newState.positionMs,
      durationMs: newState.durationMs,
      hasNextTrack: _active?.backend.hasNextTrack ?? false,
      trackUri: newState.track?.uri,
    );
  }

  /// Detects album completion by comparing current state with previous state.
  ///
  /// Returns true if:
  /// - Previous track was near end (within 5s)
  /// - Previous track had no next track (was last track)
  /// - Track changed (new track URI differs from previous)
  ///
  /// This handles the race condition with auto-advancing players (Spotify)
  /// where the SDK advances to the next track before we can check completion.
  bool _detectCompletionViaTransition(TrackInfo? newTrack) {
    final last = _lastPlaybackState;
    if (last == null) return false;

    // Track must have changed (or be null now when it wasn't before)
    final trackChanged = newTrack?.uri != last.trackUri;
    if (!trackChanged) return false;

    // Previous track must have been near end and had no next track
    if (!last.isNearEnd()) return false;
    if (last.hasNextTrack) return false;

    Log.info(
      _tag,
      'Album completion detected via transition',
      data: {
        'previousPosition': '${last.positionMs}',
        'previousDuration': '${last.durationMs}',
        'newTrack': newTrack?.uri ?? 'null',
      },
    );
    return true;
  }

  // ─── Auto-advance ───────────────────────────────────────────────────

  Future<void> _onAlbumCompleted(String? cardId, String? groupId) async {
    if (cardId == null) return;
    Log.info(
      _tag,
      'Album completed',
      data: {
        'cardId': cardId,
        'positionMs':
            '${_active?.backend.currentPositionMs ?? state.positionMs}',
        'durationMs': '${state.durationMs}',
      },
    );
    final cards = ref.read(tileItemRepositoryProvider);
    await handleAlbumCompleted(cards, cardId: cardId, groupId: groupId);
  }

  // ─── Position tracking ──────────────────────────────────────────────

  void _startPositionSave() {
    if (_positionSaveTimer != null) return;

    if (!_playStopwatch.isRunning) _playStopwatch.start();
    _positionSaveTimer = Timer.periodic(
      _positionSaveInterval,
      (_) {
        if (_active == null) return; // Backend torn down between ticks (#216)
        _updatePlayTime();
        final cardId = state.activeCardId;
        final track = state.track;
        final posMs = _active?.backend.currentPositionMs ?? state.positionMs;
        final durationMs = state.durationMs;

        // Check for album completion continuously while playing.
        // This catches natural track endings where isPlaying stays true.
        // Guard prevents repeated triggers while position lingers near end.
        if (!_completionHandledForSession &&
            isAlbumComplete(
              hasNextTrack: _active?.backend.hasNextTrack ?? false,
              positionMs: posMs,
              durationMs: durationMs,
            )) {
          _completionHandledForSession = true;
          unawaited(_onAlbumCompleted(cardId, state.activeGroupId));
        }

        if (shouldSavePositionInSession(
              playTimeMs: _playTimeMs,
              completionHandled: _completionHandledForSession,
            ) &&
            cardId != null &&
            track != null) {
          unawaited(_savePosition(cardId, track, posMs));
        }
      },
    );
  }

  void _stopPositionSave() {
    if (_positionSaveTimer == null) return;
    _positionSaveTimer!.cancel();
    _positionSaveTimer = null;
    _updatePlayTime();
    _playStopwatch.stop();
  }

  void _updatePlayTime() {
    _playTimeMs = computePlayTime(
      elapsedSinceStartMs:
          _playStopwatch.isRunning ? _playStopwatch.elapsedMilliseconds : null,
      previousPlayTimeMs: _playTimeMs,
    );
    _playStopwatch.reset();
    if (_playTimeMs > 0) _playStopwatch.start();
  }

  Future<void> _savePosition(
    String cardId,
    TrackInfo track,
    int positionMs,
  ) async {
    if (positionMs <= 0) return;

    final trackNumber = _active?.backend.currentTrackNumber ?? 0;
    try {
      await ref
          .read(tileItemRepositoryProvider)
          .savePosition(
            itemId: cardId,
            trackUri: track.uri,
            trackNumber: trackNumber,
            positionMs: positionMs,
          );
      Log.debug(
        _tag,
        'Position saved',
        data: {
          'cardId': cardId,
          'positionMs': '$positionMs',
          'trackNumber': '$trackNumber',
          'playTimeMs': '$_playTimeMs',
        },
      );
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Position save failed',
        exception: e,
        data: {'cardId': cardId, 'positionMs': '$positionMs'},
      );
    }
  }
}

// ── Extracted pure functions ─────────────────────────────────────────────
//
// Testable without instantiating PlayerNotifier. Each encodes a specific
// decision that PlayerNotifier delegates to.

/// Whether a repeat play of the active card should be ignored.
///
/// A kid re-tapping the glowing card (or re-presenting an NFC figure)
/// must not restart the backend. Internal recovery replays pass
/// [forceReplay] because they re-invoke playCard specifically to
/// rebuild a lost SDK context while playback still reads as active.
bool shouldIgnoreRepeatPlay({
  required String cardId,
  required String? activeCardId,
  required bool isPlaying,
  required bool forceReplay,
}) => !forceReplay && cardId == activeCardId && isPlaying;

/// Whether enough time has been played to justify saving position.
/// Prevents brief taps from marking episodes as "in progress".
/// Minimum play time before a position is worth saving. Prevents brief
/// taps from marking episodes as "in progress".
const _minPlayTimeMs = 20000; // 20 seconds

bool shouldSavePosition({
  required int playTimeMs,
  int minPlayTimeMs = _minPlayTimeMs,
}) => playTimeMs >= minPlayTimeMs;

/// Whether a position save is still meaningful for this listening session.
///
/// Once the album has completed, the backend keeps emitting state — Spotify
/// reports a near-zero position after it stops — and those late writes land
/// after `handleAlbumCompleted` cleared the tile, leaving a finished episode
/// with a bogus "resume here" marker (seen in the field: a completed episode
/// left at 1823ms three seconds after being marked heard).
bool shouldSavePositionInSession({
  required int playTimeMs,
  required bool completionHandled,
  int minPlayTimeMs = _minPlayTimeMs,
}) =>
    !completionHandled &&
    shouldSavePosition(playTimeMs: playTimeMs, minPlayTimeMs: minPlayTimeMs);

/// Estimate current playback position by interpolating from a known
/// anchor point. Backends that only report position on discrete events
/// (Spotify Web Playback SDK) need this to avoid stale positions
/// between events. Pure function; caller provides elapsed time from
/// a monotonic source (Stopwatch, Ticker, etc.).
int interpolatePosition({
  required int anchorMs,
  required int elapsedMs,
  required int durationMs,
  required bool isPlaying,
}) {
  if (!isPlaying || durationMs <= 0) return anchorMs;
  return (anchorMs + elapsedMs).clamp(0, durationMs);
}

/// Whether the current position is near the end of the track.
/// Used to detect album/episode completion.
bool isNearTrackEnd({
  required int positionMs,
  required int durationMs,
  int thresholdMs = _completionThresholdMs,
}) => durationMs > 0 && positionMs > durationMs - thresholdMs;

/// Whether the album is complete: last track and near the end.
bool isAlbumComplete({
  required bool hasNextTrack,
  required int positionMs,
  required int durationMs,
  int thresholdMs = _completionThresholdMs,
}) =>
    !hasNextTrack &&
    isNearTrackEnd(
      positionMs: positionMs,
      durationMs: durationMs,
      thresholdMs: thresholdMs,
    );

/// Accumulate play time from the last anchor.
/// Returns the new total. Does not mutate anything. Pure function;
/// caller provides elapsed time from a monotonic source.
int computePlayTime({
  required int? elapsedSinceStartMs,
  required int previousPlayTimeMs,
}) {
  if (elapsedSinceStartMs == null) return previousPlayTimeMs;
  return previousPlayTimeMs + elapsedSinceStartMs;
}

/// Handle album completion: mark card as heard, clear all positions in tile.
///
/// Extracted so it can be tested with an in-memory DB without
/// instantiating PlayerNotifier.
Future<void> handleAlbumCompleted(
  TileItemRepository cards, {
  required String cardId,
  String? groupId,
}) async {
  try {
    final card = await cards.getById(cardId);
    if (card == null || card.isHeard) return;

    await cards.markHeard(card.id);
    Log.info(
      'PlayerProvider',
      'Marked as heard',
      data: {
        'cardId': card.id,
        'title': card.title,
      },
    );
  } on Exception catch (e) {
    Log.error('PlayerProvider', 'Mark heard failed', exception: e);
  }

  if (groupId == null) {
    // Standalone episode: no tile to sweep, but its own near-end
    // position must still be cleared. markHeard doesn't touch it, so
    // without this a re-tap resumes at the last few seconds instead of
    // restarting the story the kid wanted to replay.
    await cards.resetPlaybackPosition(cardId);
    return;
  }

  // Clear ALL positions in the tile, including the completed episode.
  // The completed episode is now heard; its position is meaningless.
  // This gives the tile a clean slate for the next listen session.
  await cards.clearPositions(groupId);
}

/// How a Spotify bridge readiness event updates player state when
/// Spotify is not the active backend. Returns the new state, or null to
/// ignore the event.
///
/// Only an idle player follows the bridge's device readiness — it keeps
/// the kid-home "connecting..." spinner honest while the SDK warms up.
/// When a non-Spotify backend is active it owns [PlaybackState.isReady]
/// (via its own state stream), so a background Spotify device drop must
/// not flip isReady and strand a paused ARD episode on the spinner.
///
/// A readiness update also preserves any pending error: copyWith always
/// replaces error, so an incidental isReady write would otherwise wipe
/// an error before PlayerErrorHost shows the dialog.
PlaybackState? applyIdleBridgeReadiness(
  PlaybackState current, {
  required bool bridgeReady,
  required bool hasActiveBackend,
}) {
  if (hasActiveBackend) return null;
  if (bridgeReady == current.isReady) return null;
  return current.copyWith(isReady: bridgeReady, error: current.error);
}

/// State after a Spotify session is lost mid-playback (auth expired,
/// logged out, or SDK error). Playback stops and a parent-action error
/// surfaces the fox dialog and pops the player screen, instead of
/// leaving the kid on a blank, silent player.
const spotifyDisconnectedState = PlaybackState(
  error: PlayerError.spotifyAuthExpired,
);

/// Merge Spotify bridge state into current playback state.
///
/// Extracted as a top-level function so it's testable without
/// instantiating PlayerNotifier. Used by [PlayerNotifier._onBridgeEvent].
PlaybackState mergeSpotifyBridgeState(
  PlaybackState current,
  PlaybackState bridgeState,
) {
  return current.copyWith(
    isReady: bridgeState.isReady,
    isPlaying: bridgeState.isPlaying,
    // Clear loading overlay once audio starts or errors.
    isLoading:
        current.isLoading &&
        !bridgeState.isPlaying &&
        bridgeState.error == null,
    track: bridgeState.track,
    positionMs: bridgeState.positionMs,
    durationMs: bridgeState.durationMs,
    // Keep existing error if bridge has none
    // (error is always-replace, so passing null clears it).
    error: bridgeState.error ?? current.error,
  );
}

/// Play-state view for grid screens: everything they render except the
/// ticking position. A value-equal record, so position updates (several
/// per second during playback) never rebuild the grids; TrackInfo has
/// value equality and only changes on track transitions.
final playerGridStateProvider = Provider<
  ({bool isPlaying, bool isReady, TrackInfo? track, String? activeContextUri})
>((ref) {
  return ref.watch(
    playerProvider.select(
      (s) => (
        isPlaying: s.isPlaying,
        isReady: s.isReady,
        track: s.track,
        activeContextUri: s.activeContextUri,
      ),
    ),
  );
});
