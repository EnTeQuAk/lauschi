import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:lauschi/core/apple_music/apple_music_session.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/listening_repository.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/feature_flags.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_session.dart';
import 'package:lauschi/features/player/apple_music_backend.dart';
import 'package:lauschi/features/player/apple_music_drm_backend.dart';
import 'package:lauschi/features/player/apple_music_native_backend.dart';
import 'package:lauschi/features/player/listening_rules.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/play_session.dart';
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
  SpotifySession? _spotifySession;

  /// Shortcuts into the session for playback code.
  SpotifyWebViewBridge? get _bridge => _spotifySession?.bridge;
  SpotifyApi? get _api => _spotifySession?.api;

  /// Permanent subscription to the Spotify bridge state stream, for the
  /// device readiness only.
  ///
  /// The bridge is long-lived and reports readiness even when no card is
  /// playing. Playback states take the same per-card route as every
  /// other backend: a subscription to the card's own backend, bundled in
  /// _ActiveBackend.
  StreamSubscription<PlaybackState>? _bridgeSub;
  StreamSubscription<BridgeRecovery>? _recoverySub;

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

  /// The card in the player, or null when nothing is.
  PlaySession? _session;

  ListeningRepository get _listening => ref.read(listeningRepositoryProvider);

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
      _spotifySession = ref.read(spotifySessionProvider.notifier);

      // Subscribe to bridge state stream (once per provider lifetime).
      _bridgeSub ??= _spotifySession!.bridge.stateStream.listen(_onBridgeEvent);
      _recoverySub ??= _spotifySession!.bridge.recoveries.listen(
        _onBridgeRecovery,
      );

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
      unawaited(_recoverySub?.cancel());
      _recoverySub = null;
      unawaited(_active?.dispose());
      _positionSaveTimer?.cancel();
    });

    return const PlaybackState();
  }

  /// The bridge outlives every Spotify card, so this subscription only
  /// keeps the device readiness current. A Spotify card's playback
  /// states reach the player through its own [SpotifyPlayer.stateStream].
  void _onBridgeEvent(PlaybackState bridgeState) {
    if (_active?.backend is SpotifyPlayer) {
      if (bridgeState.isReady != state.isReady) {
        state = state.copyWith(
          isReady: bridgeState.isReady,
          error: state.error,
        );
      }
      return;
    }
    final updated = applyIdleBridgeReadiness(
      state,
      bridgeReady: bridgeState.isReady,
      hasActiveBackend: _active != null,
    );
    if (updated != null) state = updated;
  }

  /// The bridge's player came back after a reload or an SDK drop and lost
  /// its playback context. A card that was playing starts again, a paused
  /// one waits for the next play, which replays it through the
  /// device-lost path.
  void _onBridgeRecovery(BridgeRecovery recovery) {
    final cardId = state.activeCardId;
    if (cardId == null ||
        !shouldReplayAfterRecovery(
          spotifyActive: _active?.backend is SpotifyPlayer,
          wasPlaying: recovery.wasPlaying,
        )) {
      return;
    }
    Log.info(
      _tag,
      'Spotify player recovered, replaying',
      data: {'cardId': cardId},
    );
    unawaited(playCard(cardId, forceReplay: true));
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
    // _onBridgeEvent only follows device readiness, and a card's
    // playback states arrive through its own SpotifyPlayer, so stale
    // events from tearDown are harmless.
    assert(
      _bridgeSub != null,
      '_bridgeSub must stay alive across Spotify disconnect/reconnect. '
      'Only ref.onDispose should cancel it.',
    );

    final session = _session;
    _session = null;
    _stopPositionSave();
    if (session != null) unawaited(_closeSession(session, kidLeft: false));

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
  ///
  /// A kid who pauses in the closing credits is done with the card, so
  /// pausing is one of the moments that can finish it.
  Future<void> pause() async {
    Log.info(_tag, 'pause');
    final session = _session;
    final progress = session == null ? null : _progress(session);

    try {
      await _active?.backend.pause();
    } on Exception catch (e) {
      Log.debug(
        _tag,
        'pause failed (device likely gone)',
        data: {'error': '$e'},
      );
    }
    if (session != null && progress != null) {
      await _finishIfEnough(session, progress, moment: 'paused');
    }
  }

  /// Stop playback and tear down the backend. Resets state to idle.
  ///
  /// Unlike [pause], this releases backend resources (audio session,
  /// media player). Used when playback should fully end, not just suspend.
  Future<void> stopCard() async {
    Log.info(_tag, 'stopCard');
    final session = _session;
    _session = null;
    _stopPositionSave();
    if (session != null) await _closeSession(session, kidLeft: true);

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
        data: {'cardId': cardId},
      );
      return;
    }
    final gen = ++_playGen;
    Log.info(
      _tag,
      'playCard gen=$gen',
      data: {'cardId': cardId, 'previous': state.activeCardId ?? 'none'},
    );

    // The previous card's session ends first, while its backend can
    // still say where playback stands, and before anything can report
    // on its behalf. A recovery replay of the same card is not a new
    // listen: it continues the session on a fresh backend instead.
    final previous = _session;
    _session = null;
    _stopPositionSave();
    final continues = forceReplay && previous?.card.id == cardId;
    if (continues) {
      previous!.pauseClock();
    } else if (previous != null) {
      await _closeSession(previous, kidLeft: !forceReplay);
    }
    if (_playGen != gen) return;

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
      state = state.copyWith(error: PlayerError.contentUnavailable);
      return;
    }

    final session = continues ? previous! : PlaySession(card);
    _session = session;
    final resume = startPosition(card, continuing: continues ? session : null);

    // Set active card state with placeholder track info from DB so the
    // player screen shows cover art and title immediately. isLoading
    // signals the UI to show a loading overlay on top.
    state = state.copyWith(
      activeCardId: cardId,
      isFinished: session.finished,
      isLoading: true,
      track: TrackInfo(
        uri: card.providerUri,
        name: card.customTitle ?? card.title,
        artworkUrl: card.coverUrl,
      ),
    );

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
          await _startSpotify(card, resume, gen);
        case ProviderType.ardAudiothek:
          await _startDirect(card, resume, gen);
        case ProviderType.appleMusic:
          await _startAppleMusic(card, resume, gen);
        case ProviderType.tidal:
          Log.error(
            _tag,
            'Provider not yet supported',
            data: {'provider': card.provider},
          );
          state = state.copyWith(error: PlayerError.playbackFailed);
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

  Future<void> _startSpotify(db.TileItem card, ResumeAt resume, int gen) async {
    final session = _spotifySession;
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

    final player = SpotifyPlayer(bridge, api, contextUri: card.providerUri);
    _active = _ActiveBackend(
      player,
      player.stateStream.listen((s) => _onBackendState(gen, s)),
    );
    // Runs alongside the play command: until it lands, the player knows
    // only the SDK's track window.
    unawaited(player.loadTracks(card.providerUri));

    await _playOnDevice(api, bridge, card, resume, deviceId, gen);
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
      state = state.copyWith(error: PlayerError.spotifyNotConnected);
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
    ResumeAt resume,
    String deviceId,
    int gen,
  ) async {
    Log.info(
      _tag,
      'Playing card',
      data: {
        'uri': card.providerUri,
        'provider': card.provider,
        'resumeTrack': resume.trackUri ?? 'none',
        'resumeMs': '${resume.positionMs}',
      },
    );

    try {
      await _sendPlayCommand(api, card.providerUri, deviceId, resume);
      if (_playGen != gen) return;
    } on SpotifyDeviceNotFoundException {
      if (_playGen != gen) return;
      Log.warn(_tag, 'Device not found — reconnecting');
      await bridge.reconnect();
      final newDeviceId = await bridge.waitForDevice();
      if (_playGen != gen) return;
      if (newDeviceId == null) {
        Log.warn(_tag, 'No device ID after reconnect');
        state = state.copyWith(error: PlayerError.spotifyConnectionLost);
        return;
      }
      await Future<void>.delayed(_deviceRegistrationDelay);
      if (_playGen != gen) return;

      try {
        await _sendPlayCommand(api, card.providerUri, newDeviceId, resume);
        if (_playGen != gen) return;
      } on SpotifyDeviceNotFoundException {
        if (_playGen != gen) return;
        Log.warn(_tag, 'Device still not found after reconnect');
        state = state.copyWith(error: PlayerError.spotifyConnectionLost);
      }
    }
  }

  Future<void> _sendPlayCommand(
    SpotifyApi api,
    String spotifyUri,
    String deviceId,
    ResumeAt resume,
  ) async {
    final trackUri = resume.trackUri;
    if (trackUri != null && resume.positionMs > 0) {
      await api.play(
        spotifyUri,
        deviceId: deviceId,
        offsetUri: trackUri,
        positionMs: resume.positionMs,
      );
    } else {
      await api.play(spotifyUri, deviceId: deviceId);
    }
  }

  // ─── StreamPlayer startup ──────────────────────────────────────────

  Future<void> _startDirect(db.TileItem card, ResumeAt resume, int gen) async {
    Log.info(
      _tag,
      'Starting StreamPlayer gen=$gen',
      data: {'cardId': card.id, 'provider': card.provider},
    );
    if (card.audioUrl == null || card.audioUrl!.isEmpty) {
      Log.error(_tag, 'No audio URL', data: {'cardId': card.id});
      state = state.copyWith(error: PlayerError.noAudioUrl);
      return;
    }

    final player = StreamPlayer();
    _active = _ActiveBackend(
      player,
      player.stateStream.listen((s) => _onBackendState(gen, s)),
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
        'resumeMs': '${resume.positionMs}',
      },
    );

    // StreamPlayer.play() returns once setup (setUrl + seek + first play
    // request) is done. Subsequent playback progress and errors arrive
    // via the state stream listener registered above.
    await player.play(
      audioUrl: card.audioUrl!,
      trackInfo: trackInfo,
      positionMs: resume.positionMs,
    );
  }

  // ─── Apple Music startup ──────────────────────────────────────────

  Future<void> _startAppleMusic(
    db.TileItem card,
    ResumeAt resume,
    int gen,
  ) async {
    final amSession = ref.read(appleMusicSessionProvider.notifier);

    Log.info(_tag, 'Starting Apple Music gen=$gen', data: {'card': card.title});

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
    // When playback hits an expired/revoked token, flip the session to
    // Unauthenticated so the reconnect prompt surfaces. Apple only
    // surfaces expiry during playback, so this is the only path that can.
    void onAuthExpired() => unawaited(amSession.handleExpiredToken());

    final AppleMusicBackend player;
    if (Platform.isIOS) {
      player = AppleMusicNativeBackend(
        api: amSession.api,
        musicKit: amSession.musicKit,
        onAuthExpired: onAuthExpired,
      );
    } else {
      player = AppleMusicDrmBackend(
        streamResolver: amSession.streamResolver,
        api: amSession.api,
        musicKit: amSession.musicKit,
        developerToken: auth.developerToken,
        musicUserToken: auth.musicUserToken,
        onAuthExpired: onAuthExpired,
      );
    }

    if (_playGen != gen) return;

    _active = _ActiveBackend(
      player,
      player.stateStream.listen((s) => _onBackendState(gen, s)),
    );

    // Don't set isPlaying: true here. The EventChannel will push the
    // confirmed playing state from native player. Setting it prematurely
    // causes a brief "playing" flash if play() fails.
    state = state.copyWith(isReady: true, isLoading: true, track: trackInfo);

    // Resume from saved track position. lastTrackNumber is 1-based in DB;
    // play() expects 0-based trackIndex.
    final savedTrackIndex = resume.trackNumber > 0 ? resume.trackNumber - 1 : 0;

    await player.play(
      albumId: albumId,
      trackInfo: trackInfo,
      trackIndex: savedTrackIndex,
      positionMs: resume.positionMs,
    );
  }

  // ─── Playback state change handling ─────────────────────────────────

  /// A state from the backend that `playCard` generation [gen] started.
  /// States from an older generation's backend are dropped.
  void _onBackendState(int gen, PlaybackState backendState) {
    final session = _session;
    if (session == null || gen != _playGen) return;

    final wasPlaying = state.isPlaying;
    state = mergeBackendState(state, backendState);
    final track = backendState.track;
    final backend = _active?.backend;
    final positionMs = backend?.currentPositionMs ?? 0;
    if (track != null && backend != null && positionMs > 0) {
      session.lastPosition = (
        trackUri: track.uri,
        trackNumber: backend.currentTrackNumber,
        positionMs: positionMs,
      );
    }

    // Log play/pause transitions (not every position tick).
    if (state.isPlaying != wasPlaying) {
      Log.debug(
        _tag,
        state.isPlaying ? 'State: playing' : 'State: paused',
        data: {
          'cardId': session.card.id,
          'positionMs': '${state.positionMs}',
          'durationMs': '${state.durationMs}',
        },
      );
    }

    // #215: Log wakelock failures instead of silently swallowing.
    unawaited(
      WakelockPlus.toggle(enable: state.isPlaying).catchError((Object e) {
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

    // Backends keep reporting the end while they sit there (just_audio's
    // completed state), so only a new report of it counts.
    final endReported = backendState.reachedEnd && !session.reachedEnd;
    session.reachedEnd = backendState.reachedEnd;
    if (endReported) {
      _stopPositionSave();
      // Spotify may carry on with autoplay after the album, and nothing
      // should play past the card's end.
      unawaited(_pauseBackendQuietly());
      unawaited(_finishAtEnd(session));
      return;
    }

    if (state.isPlaying) {
      _startPositionSave();
    } else {
      _stopPositionSave();
      unawaited(_recordProgress(session));
    }
  }

  /// Where [session]'s playback on the active backend stands, or null
  /// without a backend.
  PlaybackProgress? _progress(PlaySession session) {
    final backend = _active?.backend;
    if (backend == null) return null;
    return (
      trackNumber: backend.currentTrackNumber,
      isLastTrack: !backend.hasNextTrack,
      positionMs: backend.currentPositionMs,
      trackDurationMs: state.durationMs,
      elapsedMs: backend.elapsedMs,
      durationMs: backend.contentDurationMs,
      coveredMs: session.coveredMs,
    );
  }

  /// The backend played [session]'s card to its end. That finishes it
  /// when the listen covered enough of it ([hasCoveredEnough]), not when
  /// the kid skipped through to the last chapter.
  Future<void> _finishAtEnd(PlaySession session) async {
    final progress = _progress(session);
    if (progress == null || hasCoveredEnough(progress)) {
      await _finish(session, moment: 'reached the end');
      return;
    }
    Log.info(
      _tag,
      'End reached, too little heard to count',
      data: {
        'cardId': session.card.id,
        'coveredMs': '${progress.coveredMs}',
        'durationMs': '${progress.durationMs}',
      },
    );
  }

  Future<void> _pauseBackendQuietly() async {
    try {
      await _active?.backend.pause();
    } on Exception catch (e) {
      Log.debug(_tag, 'pause after the end failed', data: {'error': '$e'});
    }
  }

  // ─── Session moments ───────────────────────────────────────────────

  /// End [session]. When the kid left the card ([kidLeft]) and it counts
  /// as finished, it is recorded as finished. Otherwise its resume point
  /// is saved, so the next play continues there.
  ///
  /// Reads the active backend, so callers run it before tearing the
  /// backend down.
  Future<void> _closeSession(
    PlaySession session, {
    required bool kidLeft,
  }) async {
    session.pauseClock();
    final progress = _progress(session);
    Log.info(
      _tag,
      'Session closed',
      data: {
        'cardId': session.card.id,
        'kidLeft': '$kidLeft',
        'playTimeMs': '${session.playTime.inMilliseconds}',
        if (progress != null) ...{
          'track': '${progress.trackNumber}',
          'lastTrack': '${progress.isLastTrack}',
          'positionMs': '${progress.positionMs}',
          'trackDurationMs': '${progress.trackDurationMs}',
          'elapsedMs': '${progress.elapsedMs}',
          'durationMs': '${progress.durationMs}',
        },
      },
    );
    if (kidLeft && progress != null) {
      await _finishIfEnough(session, progress, moment: 'left');
    }
    await _recordProgress(session, progress: progress);
  }

  Future<void> _finishIfEnough(
    PlaySession session,
    PlaybackProgress progress, {
    required String moment,
  }) async {
    if (session.finished || !isFinishedEnough(session.card, progress)) return;
    await _finish(session, moment: moment);
  }

  /// Record [session]'s card as finished, once per session.
  Future<void> _finish(PlaySession session, {required String moment}) async {
    if (session.finished) return;
    session.finished = true;
    if (identical(session, _session)) {
      state = state.copyWith(isFinished: true, error: state.error);
    }
    Log.info(
      _tag,
      'Card finished',
      data: {'cardId': session.card.id, 'moment': moment},
    );
    await session.queue(() async {
      try {
        await _listening.finishItem(session.card.id);
      } on Exception catch (e) {
        Log.error(_tag, 'Recording a finish failed', exception: e);
      }
    });
  }

  /// Bring the listening facts up to date with [session]'s play time
  /// and position: the card counts as started once it has played long
  /// enough, and a started, unfinished card keeps a resume point.
  ///
  /// The position is taken now, the writes run in the session's queue, so
  /// a save that is still waiting when the card finishes is dropped.
  Future<void> _recordProgress(
    PlaySession session, {
    PlaybackProgress? progress,
  }) {
    final current = progress ?? _progress(session);
    final trackUri = state.track?.uri;
    final playTime = session.playTime;
    return session.queue(
      () => _writeProgress(session, current, trackUri, playTime),
    );
  }

  Future<void> _writeProgress(
    PlaySession session,
    PlaybackProgress? current,
    String? trackUri,
    Duration playTime,
  ) async {
    try {
      if (!session.started && isStartedEnough(playTime)) {
        session.started = true;
        await _listening.startItem(session.card.id);
      }
      if (!session.started ||
          session.finished ||
          current == null ||
          trackUri == null ||
          current.positionMs <= 0) {
        return;
      }
      await _listening.saveResumePoint(
        itemId: session.card.id,
        trackUri: trackUri,
        trackNumber: current.trackNumber,
        positionMs: current.positionMs,
        elapsedMs: current.elapsedMs,
        durationMs: current.durationMs,
      );
      Log.debug(
        _tag,
        'Resume point saved',
        data: {
          'cardId': session.card.id,
          'trackNumber': '${current.trackNumber}',
          'lastTrack': '${current.isLastTrack}',
          'positionMs': '${current.positionMs}',
          'elapsedMs': '${current.elapsedMs}',
          'durationMs': '${current.durationMs}',
          'coveredMs': '${current.coveredMs}',
          'playTimeMs': '${playTime.inMilliseconds}',
        },
      );
    } on Exception catch (e) {
      Log.error(
        _tag,
        'Recording progress failed',
        exception: e,
        data: {'cardId': session.card.id},
      );
    }
  }

  // ─── Position tracking ──────────────────────────────────────────────

  void _startPositionSave() {
    final session = _session;
    if (session == null || _positionSaveTimer != null) return;
    session.resumeClock();
    _positionSaveTimer = Timer.periodic(_positionSaveInterval, (_) {
      // Backend torn down between ticks (#216), or the session ended.
      if (_active == null || !identical(_session, session)) return;
      unawaited(_recordProgress(session));
    });
  }

  void _stopPositionSave() {
    _session?.pauseClock();
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
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

/// Whether a bridge recovery restarts the active card: only when Spotify
/// is the active backend and the card was playing when the player was
/// lost.
bool shouldReplayAfterRecovery({
  required bool spotifyActive,
  required bool wasPlaying,
}) => spotifyActive && wasPlaying;

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

/// Merge a backend's state into the player's state.
///
/// Extracted as a top-level function so it's testable without
/// instantiating PlayerNotifier. [PlaybackState.reachedEnd] stays with
/// the backend: the player decides on it in its state handler.
PlaybackState mergeBackendState(
  PlaybackState current,
  PlaybackState backendState,
) {
  return current.copyWith(
    isReady: backendState.isReady,
    isPlaying: backendState.isPlaying,
    // Clear loading overlay once audio starts or errors.
    isLoading:
        current.isLoading &&
        !backendState.isPlaying &&
        backendState.error == null,
    track: backendState.track ?? current.track,
    positionMs: backendState.positionMs,
    durationMs: backendState.durationMs,
    // Keep existing error if the backend has none
    // (error is always-replace, so passing null clears it).
    error: backendState.error ?? current.error,
  );
}

/// Play-state view for grid screens: everything they render except the
/// ticking position. A value-equal record, so position updates (several
/// per second during playback) never rebuild the grids; TrackInfo has
/// value equality and only changes on track transitions.
typedef PlayerGridState =
    ({
      bool isPlaying,
      bool isReady,
      bool isLoading,
      bool isFinished,
      TrackInfo? track,
      String? activeCardId,
    });

final playerGridStateProvider = Provider<PlayerGridState>((ref) {
  return ref.watch(
    playerProvider.select(
      (s) => (
        isPlaying: s.isPlaying,
        isReady: s.isReady,
        isLoading: s.isLoading,
        isFinished: s.isFinished,
        track: s.track,
        activeCardId: s.activeCardId,
      ),
    ),
  );
});
