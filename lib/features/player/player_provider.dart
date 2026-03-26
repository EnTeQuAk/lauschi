import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/apple_music_native_backend.dart';
import 'package:lauschi/features/player/apple_music_player.dart';
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

  /// Stop playback and cancel the state subscription.
  /// Does NOT dispose the backend — call [dispose] for full cleanup.
  Future<void> stop() async {
    await _subscription?.cancel();
    await backend.stop();
  }

  /// Full cleanup: cancel subscription and release backend resources.
  /// Only called on app shutdown, not during normal backend switching.
  Future<void> dispose() async {
    await _subscription?.cancel();
    await backend.dispose();
  }
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

  // -- Timing constants --
  static const _deviceRegistrationDelay = Duration(milliseconds: 500);
  static const _completionThresholdMs = 5000;
  static const _positionSaveInterval = Duration(seconds: 10);

  // -- Position tracking state --
  int _playTimeMs = 0;
  DateTime? _playStartedAt;

  /// Minimum play time before saving position. Prevents brief taps from
  /// marking episodes as "in progress".
  static const _minPlayTimeMs = 20000; // 20 seconds

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
        if (next is SpotifyUnauthenticated || next is SpotifyError) {
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
        unawaited(playCard(cardId));
        return;
      }

      // Single write: merge isReady + playback fields.
      state = mergeSpotifyBridgeState(state, bridgeState);
      _onPlaybackStateChange(state);
    } else if (bridgeState.isReady != state.isReady) {
      // Non-Spotify: only accept readiness changes so the bridge stays
      // warm for the UI ("connecting..." spinner on kid home screen).
      state = state.copyWith(isReady: bridgeState.isReady);
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

    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _playTimeMs = 0;
    _playStartedAt = null;

    unawaited(_active?.stop());
    _active = null;
    state = const PlaybackState();
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
  Future<void> playCard(String cardId) async {
    final gen = ++_playGen;
    Log.info(
      _tag,
      'playCard gen=$gen',
      data: {'cardId': cardId, 'previous': state.activeCardId ?? 'none'},
    );

    // Cancel pending timers and reset tracking.

    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    _playTimeMs = 0;
    _playStartedAt = null;

    final card = await ref.read(tileItemRepositoryProvider).getById(cardId);
    if (card == null) {
      Log.error(_tag, 'Card not found', data: {'cardId': cardId});
      return;
    }
    if (_playGen != gen) {
      Log.debug(_tag, 'playCard gen=$gen superseded (now $_playGen), bailing');
      return;
    }

    // Check content expiration.
    if (card.availableUntil != null &&
        card.availableUntil!.isBefore(DateTime.now())) {
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
    if (_playTimeMs >= _minPlayTimeMs &&
        oldCardId != null &&
        oldTrack != null) {
      Log.info(
        _tag,
        'Saving position on card switch',
        data: {
          'oldCardId': oldCardId,
          'positionMs': oldPos,
          'playTimeMs': _playTimeMs,
        },
      );
      unawaited(_savePosition(oldCardId, oldTrack, oldPos));
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
      await previousBackend.stop();
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
        await playCard(cardId);
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
        _onPlaybackStateChange(state);
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

    // Fire-and-forget: StreamPlayer.play() awaits just_audio's play(),
    // which only completes when the track finishes. We don't want to
    // block here because the caller needs to clear isLoading promptly.
    // Errors are surfaced through the state stream.
    unawaited(
      player.play(
        audioUrl: card.audioUrl!,
        trackInfo: trackInfo,
        positionMs: card.lastPositionMs,
      ),
    );
  }

  // ─── AppleMusicPlayer startup ─────────────────────────────────────

  Future<void> _startAppleMusic(db.TileItem card, int gen) async {
    final amSession = ref.read(appleMusicSessionProvider.notifier);

    Log.info(
      _tag,
      'Starting AppleMusicPlayer gen=$gen',
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
    final PlayerBackend player;
    if (Platform.isIOS) {
      player = AppleMusicNativeBackend(
        api: amSession.api,
        musicKit: amSession.musicKit,
      );
    } else {
      player = AppleMusicPlayer(
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
        _onPlaybackStateChange(state);
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

    // Both backends have the same play() signature.
    final playFn =
        player is AppleMusicNativeBackend
            ? player.play
            : (player as AppleMusicPlayer).play;
    await playFn(
      albumId: albumId,
      trackInfo: trackInfo,
      trackIndex: savedTrackIndex,
      positionMs: card.lastPositionMs,
    );
  }

  // ─── Playback state change handling ─────────────────────────────────

  void _onPlaybackStateChange(PlaybackState newState) {
    // No active backend → no side effects.
    if (_active == null) return;

    // Log play/pause transitions (not every position tick).
    if (newState.isPlaying != state.isPlaying) {
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

    if (newState.isPlaying) {
      _startPositionSave();
    } else {
      _stopPositionSave();

      // Capture values now — by the time the async save/mark-heard runs,
      // a new card may own state and these fields would be wrong.
      final cardId = state.activeCardId;
      final track = state.track;
      final posMs = _active?.backend.currentPositionMs ?? newState.positionMs;

      if (_playTimeMs >= _minPlayTimeMs && cardId != null && track != null) {
        unawaited(_savePosition(cardId, track, posMs));
      }

      // Album completion: paused on last track, within threshold of end.
      final groupId = state.activeGroupId;
      final backend = _active?.backend;
      final hasNextTrack = backend?.hasNextTrack ?? false;
      final isNearEnd =
          newState.durationMs > 0 &&
          posMs > newState.durationMs - _completionThresholdMs;
      if (!hasNextTrack && isNearEnd) {
        unawaited(_onAlbumCompleted(cardId, groupId));
      }
    }
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
    await _markAlbumHeard(cardId);

    if (groupId == null) return;

    // Clear stale resume positions for sibling episodes so the next
    // one starts fresh.
    // TODO(#228): extract into PlaybackSideEffects provider (event system)
    final cards = ref.read(tileItemRepositoryProvider);
    await cards.clearPositions(groupId, excludeItemId: cardId);
  }

  // ─── Position tracking ──────────────────────────────────────────────

  void _startPositionSave() {
    if (_positionSaveTimer != null) return;

    _playStartedAt ??= DateTime.now();
    _positionSaveTimer = Timer.periodic(
      _positionSaveInterval,
      (_) {
        // Guard: skip if backend was torn down between ticks. See #216.
        if (_active == null) return;
        _updatePlayTime();
        final cardId = state.activeCardId;
        final track = state.track;
        final posMs = _active?.backend.currentPositionMs ?? state.positionMs;
        if (_playTimeMs >= _minPlayTimeMs && cardId != null && track != null) {
          unawaited(_savePosition(cardId, track, posMs));
        }
      },
    );
  }

  void _stopPositionSave() {
    if (_positionSaveTimer == null) return;
    _positionSaveTimer!.cancel();
    _positionSaveTimer = null;
    if (_playStartedAt != null) {
      _updatePlayTime();
      _playStartedAt = null;
    }
  }

  void _updatePlayTime() {
    if (_playStartedAt != null) {
      _playTimeMs += DateTime.now().difference(_playStartedAt!).inMilliseconds;
      _playStartedAt = DateTime.now();
    }
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

  Future<void> _markAlbumHeard(String cardId) async {
    try {
      final cards = ref.read(tileItemRepositoryProvider);
      final card = await cards.getById(cardId);
      if (card == null || card.isHeard) return;

      await cards.markHeard(card.id);
      Log.info(
        _tag,
        'Marked as heard',
        data: {'cardId': card.id, 'title': card.title},
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Mark heard failed', exception: e);
    }
  }
}

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
