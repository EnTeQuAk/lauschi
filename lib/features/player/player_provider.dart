import 'dart:async' show StreamSubscription, Timer, unawaited;

import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/features/player/direct_player.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_backend.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'player_provider.g.dart';

const _tag = 'PlayerProvider';

// ---------------------------------------------------------------------------
// Providers for shared services
// TODO(#206): spotifyApiProvider is used outside the player feature (parent
// screens). Move to core/spotify/ in a provider-organization pass.
// ---------------------------------------------------------------------------

@Riverpod(keepAlive: true)
SpotifyApi spotifyApi(Ref ref) {
  final api = SpotifyApi();

  ref.listen(spotifyAuthProvider, (_, next) {
    if (next is AuthAuthenticated) {
      api.updateToken(next.tokens.accessToken);
    }
  });

  final authState = ref.read(spotifyAuthProvider);
  if (authState is AuthAuthenticated) {
    api.updateToken(authState.tokens.accessToken);
  }

  // Wire 401 → refresh → retry.
  api.onTokenExpired = () {
    return ref.read(spotifyAuthProvider.notifier).validAccessToken();
  };

  return api;
}

/// Holds the [MediaSessionHandler] initialized in main().
/// Must be overridden before use.
@Riverpod(keepAlive: true)
MediaSessionHandler mediaSessionHandler(Ref ref) {
  throw StateError(
    'mediaSessionHandlerProvider must be overridden with an '
    'initialized MediaSessionHandler',
  );
}

@Riverpod(keepAlive: true)
SpotifyPlayerBridge spotifyPlayerBridge(Ref ref) {
  final bridge = SpotifyPlayerBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
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
/// media session, and auto-advance.
@Riverpod(keepAlive: true)
class PlayerNotifier extends _$PlayerNotifier {
  late SpotifyPlayerBridge _bridge;
  late SpotifyApi _api;
  late MediaSessionHandler _mediaSession;

  /// Permanent subscription to the Spotify bridge state stream.
  /// Routes playback events only when Spotify is the active backend;
  /// always accepts device metadata (isReady).
  ///
  /// This is intentionally asymmetric with DirectPlayer's per-play
  /// subscription (bundled in _ActiveBackend). The bridge is long-lived
  /// and reports device readiness even when no card is playing;
  /// DirectPlayer is created per-play and dies with the backend.
  StreamSubscription<PlaybackState>? _bridgeSub;

  /// The currently active backend + its subscription, or null.
  _ActiveBackend? _active;

  Timer? _advanceTimer;
  Timer? _positionSaveTimer;

  /// Monotonically increasing generation counter. Each [playCard] call
  /// increments this. Stale async continuations compare their captured
  /// generation and bail out if superseded.
  int _playGen = 0;

  // -- Timing constants --
  static const _deviceRegistrationDelay = Duration(milliseconds: 500);
  static const _completionThresholdMs = 5000;
  static const _advanceDelay = Duration(seconds: 3);
  static const _positionSaveInterval = Duration(seconds: 10);

  // -- Position tracking state --
  int _playTimeMs = 0;
  DateTime? _playStartedAt;

  /// Minimum play time before saving position. Prevents brief taps from
  /// marking episodes as "in progress".
  static const _minPlayTimeMs = 20000; // 20 seconds

  @override
  PlaybackState build() {
    _bridge = ref.watch(spotifyPlayerBridgeProvider);
    _api = ref.watch(spotifyApiProvider);
    _mediaSession = ref.watch(mediaSessionHandlerProvider);

    // Wire system media button callbacks.
    _mediaSession.onPlay = resume;
    _mediaSession.onPause = () => unawaited(pause());
    _mediaSession.onSkipNext = () => unawaited(nextTrack());
    _mediaSession.onSkipPrev = () => unawaited(prevTrack());
    _mediaSession.onSeek = (pos) => unawaited(seek(pos.inMilliseconds));

    // Bridge subscription: always accept device metadata; only route
    // playback fields when SpotifyBackend is the active backend.
    unawaited(_bridgeSub?.cancel());
    _bridgeSub = _bridge.stateStream.listen(_onBridgeEvent);

    ref.onDispose(() {
      unawaited(_bridgeSub?.cancel());
      unawaited(_active?.dispose());
      _positionSaveTimer?.cancel();
      _advanceTimer?.cancel();
    });

    return const PlaybackState();
  }

  void _onBridgeEvent(PlaybackState bridgeState) {
    final isSpotifyActive = _active?.backend is SpotifyBackend;

    if (isSpotifyActive) {
      // Single write: merge isReady + playback fields.
      state = state.copyWith(
        isReady: bridgeState.isReady,
        isPlaying: bridgeState.isPlaying,
        track: bridgeState.track,
        positionMs: bridgeState.positionMs,
        durationMs: bridgeState.durationMs,
        // Keep existing error if bridge has none
        // (error is always-replace, so passing null clears it).
        error: bridgeState.error ?? state.error,
      );
      _onPlaybackStateChange(state);
    } else if (bridgeState.isReady != state.isReady) {
      // Non-Spotify: only accept readiness changes so the bridge stays
      // warm for the UI ("connecting..." spinner on kid home screen).
      state = state.copyWith(isReady: bridgeState.isReady);
    }
  }

  // ─── Public API ──────────────────────────────────────────────────────

  /// Initialize the bridge with current auth tokens.
  /// Call after successful Spotify login.
  Future<void> initBridge() async {
    final authState = ref.read(spotifyAuthProvider);
    if (authState is! AuthAuthenticated) {
      Log.warn(_tag, 'Cannot init bridge — not authenticated');
      return;
    }

    final authNotifier = ref.read(spotifyAuthProvider.notifier);
    await _bridge.init(
      getValidToken: () async {
        final token = await authNotifier.validAccessToken();
        if (token == null) throw StateError('Not authenticated');
        return token;
      },
    );
    Log.info(_tag, 'Bridge initialized');
  }

  /// Pause playback (idempotent).
  Future<void> pause() async {
    Log.info(_tag, 'pause');
    _advanceTimer?.cancel();
    await _backendCommand('pause', (b) => b.pause());
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
    _advanceTimer?.cancel();
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
    _advanceTimer?.cancel();
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

    // Set active card state. Error is always-replace (omitting clears it).
    state = state.copyWith(
      activeCardId: cardId,
      activeContextUri: card.providerUri,
      activeGroupId: card.groupId,
      clearNextEpisode: true,
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
    if (_bridge.currentState.isPlaying) {
      await _bridge.pause();
    }

    // Tear down previous backend. Await ensures clean handoff.
    if (_active != null) {
      Log.debug(
        _tag,
        'Tearing down ${_active!.backend.runtimeType} gen=$gen',
      );
    }
    await _active?.stop();
    _active = null;
    if (_playGen != gen) {
      Log.debug(_tag, 'playCard gen=$gen superseded during teardown');
      return;
    }

    // Create and activate new backend.
    try {
      switch (card.provider) {
        case 'spotify':
          await _startSpotify(card, gen);
        case 'ard_audiothek':
          await _startDirect(card, gen);
        default:
          Log.error(
            _tag,
            'Unsupported provider',
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
      );
    }
  }

  // ─── Backend command dispatch ────────────────────────────────────────

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
    } on Exception catch (e) {
      Log.error(_tag, '$name failed', exception: e);
      state = state.copyWith(error: PlayerError.playbackCommandFailed);
    }
  }

  // ─── Spotify startup ────────────────────────────────────────────────

  Future<void> _startSpotify(db.TileItem card, int gen) async {
    Log.info(
      _tag,
      'Starting Spotify backend gen=$gen',
      data: {'uri': card.providerUri},
    );
    // Proactively refresh the token before attempting playback.
    final authNotifier = ref.read(spotifyAuthProvider.notifier);
    final token = await authNotifier.validAccessToken();
    if (_playGen != gen) return;
    if (token == null) {
      state = state.copyWith(
        error: PlayerError.spotifyAuthExpired,
      );
      return;
    }
    _api.updateToken(token);

    final deviceId = await _ensureDevice(gen);
    if (deviceId == null || _playGen != gen) return;

    // Activate the backend only after we have a device — avoids a zombie
    // _active pointing to a backend that can't play. SpotifyBackend routes
    // state through the bridge subscription; the _ActiveBackend subscription
    // is a no-op that keeps the pair consistent.
    // SpotifyBackend routes state through _onBridgeEvent, so no
    // per-backend subscription needed.
    _active = _ActiveBackend(SpotifyBackend(_bridge, _api));

    await _playOnDevice(card, deviceId, gen);
  }

  /// Get a valid device ID, reconnecting if needed. Returns null on failure.
  Future<String?> _ensureDevice(int gen) async {
    final currentDeviceId = _bridge.deviceId;
    if (currentDeviceId != null) return currentDeviceId;

    Log.warn(_tag, 'No device ID — attempting reconnect');
    await _bridge.reconnect();
    final deviceId = await _bridge.waitForDevice();
    if (_playGen != gen) return null;
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
      await _sendPlayCommand(card.providerUri, deviceId, card);
      if (_playGen != gen) return;
    } on SpotifyDeviceNotFoundException {
      if (_playGen != gen) return;
      // Device stale — reconnect once.
      Log.warn(_tag, 'Device not found — reconnecting');
      final newDeviceId = await _ensureDevice(gen);
      if (newDeviceId == null || _playGen != gen) return;

      try {
        await _sendPlayCommand(card.providerUri, newDeviceId, card);
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
    String spotifyUri,
    String deviceId,
    db.TileItem card,
  ) async {
    if (card.lastTrackUri != null && card.lastPositionMs > 0) {
      await _api.play(
        spotifyUri,
        deviceId: deviceId,
        offsetUri: card.lastTrackUri,
        positionMs: card.lastPositionMs,
      );
    } else {
      await _api.play(spotifyUri, deviceId: deviceId);
    }
  }

  // ─── DirectPlayer startup ──────────────────────────────────────────

  Future<void> _startDirect(db.TileItem card, int gen) async {
    Log.info(
      _tag,
      'Starting DirectPlayer gen=$gen',
      data: {'cardId': card.id, 'provider': card.provider},
    );
    if (card.audioUrl == null || card.audioUrl!.isEmpty) {
      Log.error(_tag, 'No audio URL', data: {'cardId': card.id});
      state = state.copyWith(
        error: PlayerError.noAudioUrl,
      );
      return;
    }

    final player = DirectPlayer();
    _active = _ActiveBackend(
      player,
      player.stateStream.listen((directState) {
        if (_playGen != gen) return;
        state = state.copyWith(
          isPlaying: directState.isPlaying,
          isReady: directState.isReady,
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

    await player.play(
      audioUrl: card.audioUrl!,
      trackInfo: trackInfo,
      positionMs: card.lastPositionMs,
    );
    if (_playGen != gen) return;
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

    unawaited(
      WakelockPlus.toggle(enable: newState.isPlaying).catchError((_) {}),
    );
    _mediaSession.updateFromAppState(
      newState,
      hasNextTrack: _active?.backend.hasNextTrack ?? false,
    );

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
      final backend = _active?.backend;
      final hasNextTrack = backend?.hasNextTrack ?? false;
      final isNearEnd =
          newState.durationMs > 0 &&
          posMs > newState.durationMs - _completionThresholdMs;
      if (!hasNextTrack && isNearEnd) {
        unawaited(_onAlbumCompleted(cardId));
      }
    }
  }

  // ─── Auto-advance ───────────────────────────────────────────────────

  Future<void> _onAlbumCompleted(String? cardId) async {
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

    final groupId = state.activeGroupId;
    if (groupId == null) return;

    final groups = ref.read(tileRepositoryProvider);
    final group = await groups.getById(groupId);
    if (group == null || group.contentType != 'hoerspiel') return;

    final nextCard = await groups.nextUnheard(groupId);
    if (nextCard == null) {
      Log.info(_tag, 'Series finished — no more episodes');
      return;
    }

    Log.info(
      _tag,
      'Auto-advance',
      data: {
        'groupId': groupId,
        'nextCard': nextCard.title,
        'nextId': nextCard.id,
      },
    );

    // Brief pause before advancing so the transition feels intentional.
    _advanceTimer?.cancel();
    _advanceTimer = Timer(_advanceDelay, () {
      unawaited(playCard(nextCard.id));
    });

    state = state.copyWith(
      nextEpisodeTitle: nextCard.customTitle ?? nextCard.title,
      nextEpisodeCoverUrl: nextCard.coverUrl,
    );
  }

  // ─── Position tracking ──────────────────────────────────────────────

  void _startPositionSave() {
    if (_positionSaveTimer != null) return;

    _playStartedAt ??= DateTime.now();
    _positionSaveTimer = Timer.periodic(
      _positionSaveInterval,
      (_) {
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

  /// Save position to DB. All arguments are captured at the call site
  /// to avoid reading stale [state] fields after an async gap.
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

  /// Mark a card as heard. [cardId] is captured at the call site.
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
