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
import 'package:lauschi/features/player/player_state.dart';
import 'package:lauschi/features/player/spotify_backend.dart';
import 'package:lauschi/features/player/spotify_player_bridge.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'player_provider.g.dart';

const _tag = 'PlayerProvider';

@Riverpod(keepAlive: true)
SpotifyApi spotifyApi(Ref ref) {
  final api = SpotifyApi();

  // Keep API token in sync with auth state.
  ref.listen(spotifyAuthProvider, (_, next) {
    if (next is AuthAuthenticated) {
      api.updateToken(next.tokens.accessToken);
    }
  });

  // Set initial token if already authenticated.
  final authState = ref.read(spotifyAuthProvider);
  if (authState is AuthAuthenticated) {
    api.updateToken(authState.tokens.accessToken);
  }

  // Wire 401 → refresh → retry. When the API gets a 401, it asks the
  // auth notifier for a fresh token and retries the request once.
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

/// Manages playback state and coordinates bridge + API.
@Riverpod(keepAlive: true)
class PlayerNotifier extends _$PlayerNotifier {
  SpotifyPlayerBridge? _bridge;
  SpotifyApi? _api;
  MediaSessionHandler? _mediaSession;
  StreamSubscription<PlaybackState>? _subscription;
  StreamSubscription<PlaybackState>? _backendSubscription;
  Timer? _positionSaveTimer;

  /// Active playback backend. Set by [playCard], used by control methods.
  PlayerBackend? _activeBackend;

  Timer? _advanceTimer;

  @override
  PlaybackState build() {
    _bridge = ref.watch(spotifyPlayerBridgeProvider);
    _api = ref.watch(spotifyApiProvider);
    _mediaSession = ref.watch(mediaSessionHandlerProvider);

    // Wire system media button callbacks → our methods.
    if (_mediaSession != null) {
      _mediaSession!.onPlay = resume;
      _mediaSession!.onPause = () => unawaited(pause());
      _mediaSession!.onSkipNext = () => unawaited(nextTrack());
      _mediaSession!.onSkipPrev = () => unawaited(prevTrack());
      _mediaSession!.onSeek = (pos) => unawaited(seek(pos.inMilliseconds));
    }

    unawaited(_subscription?.cancel());
    _subscription = _bridge!.stateStream.listen((playbackState) {
      state = playbackState;
      _onStateChange(playbackState);
    });

    ref.onDispose(() {
      unawaited(_subscription?.cancel());
      unawaited(_backendSubscription?.cancel());
      _positionSaveTimer?.cancel();
      _advanceTimer?.cancel();
      unawaited(_activeBackend?.dispose());
    });

    return const PlaybackState();
  }

  /// Initialize the bridge with current auth tokens.
  /// Call after successful Spotify login.
  Future<void> initBridge() async {
    final authState = ref.read(spotifyAuthProvider);
    if (authState is! AuthAuthenticated) {
      Log.warn(_tag, 'Cannot init bridge — not authenticated');
      return;
    }

    final authNotifier = ref.read(spotifyAuthProvider.notifier);
    await _bridge!.init(
      getValidToken: () async {
        final token = await authNotifier.validAccessToken();
        if (token == null) throw StateError('Not authenticated');
        return token;
      },
    );
    Log.info(_tag, 'Bridge initialized');
  }

  /// Play a raw Spotify URI (album, playlist, or track).
  ///
  /// Prefer [playCard] which handles provider branching, expiration checks,
  /// and resume state. This method does not set `activeCardId`, so position
  /// saving and mark-heard will not work.
  @Deprecated('Use playCard(cardId) instead')
  Future<void> play(String spotifyUri) async {
    final deviceId = state.deviceId;
    if (deviceId == null || _api == null) {
      Log.error(_tag, 'Cannot play — no device ID');
      return;
    }

    state = state.copyWith(
      activeContextUri: spotifyUri,
      clearActiveCard: true,
      clearActiveGroupId: true,
    );
    Log.info(_tag, 'Playing', data: {'uri': spotifyUri});

    try {
      await _api!.play(spotifyUri, deviceId: deviceId);
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
    }
  }

  /// Pause playback (idempotent — safe to call when already paused).
  Future<void> pause() async {
    _advanceTimer?.cancel();
    await _backendCommand('pause', (b) => b.pause());
  }

  /// Resume playback (idempotent — safe to call when already playing).
  Future<void> resume() async {
    await _backendCommand('resume', (b) => b.resume());
  }

  /// Toggle play/pause.
  Future<void> togglePlay() async {
    _advanceTimer?.cancel();
    if (state.isPlaying) {
      await _backendCommand('pause', (b) => b.pause());
    } else {
      await _backendCommand('resume', (b) => b.resume());
    }
  }

  /// Skip to next track. No-op for single-file backends.
  Future<void> nextTrack() async {
    await _backendCommand('next', (b) => b.nextTrack());
  }

  /// Skip to previous track. No-op for single-file backends.
  Future<void> prevTrack() async {
    await _backendCommand('prev', (b) => b.prevTrack());
  }

  /// Clear any error state.
  void clearError() {
    _advanceTimer?.cancel();
    // ignore: avoid_redundant_argument_values, null clears the error
    state = state.copyWith(error: null);
  }

  /// Seek to position in milliseconds.
  Future<void> seek(int positionMs) async {
    await _backendCommand('seek', (b) => b.seek(positionMs));
  }

  /// Delegate a command to the active backend with error handling.
  Future<void> _backendCommand(
    String name,
    Future<void> Function(PlayerBackend) command,
  ) async {
    final backend = _activeBackend;
    if (backend == null) return;
    try {
      await command(backend);
    } on Exception catch (e) {
      Log.error(_tag, '$name failed', exception: e);
      state = state.copyWith(error: 'Steuerung fehlgeschlagen');
    }
  }

  /// Resume playback for a card, restoring saved position.
  ///
  /// Looks up the card by ID, branches on provider, and restores resume
  /// state. Group ID for auto-advance comes from the card's groupId field.
  Future<void> playCard(String cardId) async {
    // Cancel any pending auto-advance and position save timer.
    _advanceTimer?.cancel();
    _positionSaveTimer?.cancel();
    // Reset play time tracking for the new card.
    _playTimeMs = 0;
    _playStartedAt = null;

    final cards = ref.read(tileItemRepositoryProvider);
    final card = await cards.getById(cardId);
    if (card == null) {
      Log.error(_tag, 'Card not found', data: {'cardId': cardId});
      return;
    }

    // Check content expiration before attempting playback.
    if (card.availableUntil != null &&
        card.availableUntil!.isBefore(DateTime.now())) {
      // Don't set activeCardId — prevents stale state from leaking into
      // position saves or mark-heard operations.
      state = state.copyWith(
        error: 'Diese Geschichte ist leider nicht mehr verfügbar',
      );
      return;
    }

    // Set active state only after validation passes.
    state = state.copyWith(
      activeCardId: cardId,
      activeContextUri: card.providerUri,
      activeGroupId: card.groupId,
      isLoading: true,
      // ignore: avoid_redundant_argument_values, null clears previous error
      error: null,
      clearNextEpisode: true,
    );

    // Stop the previous backend before switching. Prevents dual playback
    // and stale state from the previous backend bleeding into position saves.
    await _activeBackend?.stop();
    unawaited(_backendSubscription?.cancel());
    _backendSubscription = null;

    switch (card.provider) {
      case 'spotify':
        _activeBackend = SpotifyBackend(_bridge!);
        await _playSpotify(card);
      case 'ard_audiothek':
        final player = DirectPlayer();
        _activeBackend = player;
        await _playDirect(card, player);
      // Future: case 'apple_music':
      default:
        Log.error(
          _tag,
          'Unsupported provider',
          data: {'provider': card.provider},
        );
        state = state.copyWith(
          isLoading: false,
          error: 'Anbieter nicht unterstützt: ${card.provider}',
        );
    }
  }

  /// Play via Spotify Web Playback SDK.
  Future<void> _playSpotify(db.TileItem card) async {
    // Proactively refresh the token before attempting playback.
    // Avoids a 401 → refresh → retry round-trip on every play after expiry.
    final authNotifier = ref.read(spotifyAuthProvider.notifier);
    final token = await authNotifier.validAccessToken();
    if (token == null) {
      Log.error(_tag, 'Cannot play — not authenticated');
      state = state.copyWith(
        isLoading: false,
        error: 'Spotify nicht verbunden — bitte neu anmelden',
      );
      return;
    }
    _api?.updateToken(token);

    final deviceId = state.deviceId;
    if (deviceId == null || _api == null) {
      // No device — try reconnecting the SDK before giving up.
      Log.warn(_tag, 'No device ID — attempting reconnect');
      await _bridge!.reconnect();
      final newDeviceId = await _bridge!.waitForDevice();
      if (newDeviceId == null || _api == null) {
        Log.warn(_tag, 'Cannot play — no device ID after reconnect');
        state = state.copyWith(
          isLoading: false,
          error: 'Spotify nicht verbunden',
        );
        return;
      }
      // Brief delay for Spotify's servers to register the new device.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      return _playOnDeviceWithRetry(card, newDeviceId);
    }

    return _playOnDeviceWithRetry(card, deviceId);
  }

  /// Send play command with one reconnect retry on device-not-found.
  Future<void> _playOnDeviceWithRetry(
    db.TileItem card,
    String deviceId,
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
      await _playOnDevice(card.providerUri, deviceId, card);
      state = state.copyWith(isLoading: false);
    } on SpotifyDeviceNotFoundException {
      // Device stale — reconnect the SDK and retry once.
      Log.warn(_tag, 'Device not found — reconnecting');
      await _reconnectAndRetry(card);
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
      state = state.copyWith(
        isLoading: false,
        error: 'Wiedergabe fehlgeschlagen',
      );
    }
  }

  /// Reconnect the SDK and retry playback once.
  ///
  /// After getting a new device_id, waits briefly for Spotify's servers
  /// to register the device before sending the play command. If the retry
  /// still fails with device-not-found, logs a warning (expected transient
  /// condition) instead of a Sentry error.
  Future<void> _reconnectAndRetry(db.TileItem card) async {
    await _bridge!.reconnect();
    final newDeviceId = await _bridge!.waitForDevice();
    if (newDeviceId == null) {
      Log.warn(_tag, 'Reconnect timed out — no device');
      state = state.copyWith(
        isLoading: false,
        error: 'Spotify-Verbindung verloren',
      );
      return;
    }

    // Brief delay for Spotify's servers to register the new device.
    // The SDK fires 'ready' locally before the REST API recognizes
    // the device_id, causing a second 404 without this.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    try {
      await _playOnDevice(card.providerUri, newDeviceId, card);
      state = state.copyWith(isLoading: false);
    } on SpotifyDeviceNotFoundException {
      // Propagation delay — device registered locally but REST API
      // hasn't caught up. Transient condition, not a code bug.
      Log.warn(_tag, 'Device still not found after reconnect');
      state = state.copyWith(
        isLoading: false,
        error: 'Spotify-Verbindung verloren',
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Retry after reconnect failed', exception: e);
      state = state.copyWith(
        isLoading: false,
        error: 'Wiedergabe fehlgeschlagen',
      );
    }
  }

  /// Send play command to Spotify API on the given device.
  Future<void> _playOnDevice(
    String spotifyUri,
    String deviceId,
    db.TileItem? card,
  ) async {
    if (card != null && card.lastTrackUri != null && card.lastPositionMs > 0) {
      await _api!.play(
        spotifyUri,
        deviceId: deviceId,
        offsetUri: card.lastTrackUri,
        positionMs: card.lastPositionMs,
      );
    } else {
      await _api!.play(spotifyUri, deviceId: deviceId);
    }
  }

  /// Play via DirectPlayer (just_audio) for HTTP audio URLs.
  ///
  /// Used for ARD Audiothek and any future non-SDK provider.
  Future<void> _playDirect(db.TileItem card, DirectPlayer player) async {
    if (card.audioUrl == null || card.audioUrl!.isEmpty) {
      Log.error(_tag, 'No audio URL', data: {'cardId': card.id});
      state = state.copyWith(
        isLoading: false,
        error: 'Keine Audio-URL verfügbar',
      );
      return;
    }

    // Stop Spotify playback if active (avoid two players at once).
    if (_bridge?.currentState.isPlaying ?? false) {
      await _bridge?.pause();
    }

    // Subscribe to direct player state (replaces Spotify bridge events).
    _backendSubscription = player.stateStream.listen((directState) {
      state = directState;
      _onStateChange(directState);
    });

    final trackInfo = TrackInfo(
      uri: card.providerUri,
      name: card.customTitle ?? card.title,
      artist: '', // ARD items don't have a per-track artist
      album: '', // Will be the show title once we have it
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

    try {
      await player.play(
        audioUrl: card.audioUrl!,
        trackInfo: trackInfo,
        positionMs: card.lastPositionMs,
      );
      state = state.copyWith(isLoading: false);
    } on Exception catch (e) {
      Log.error(_tag, 'Direct play failed', exception: e);
      state = state.copyWith(
        isLoading: false,
        error: 'Wiedergabe fehlgeschlagen',
      );
    }
  }

  /// Save position periodically while playing. Toggle wakelock.
  /// Sync media session notification. Detect album completion.
  void _onStateChange(PlaybackState newState) {
    // Keep screen on while audio plays; release on pause/stop.
    // Wakelock requires a foreground activity — catches
    // NoActivityException when the app is backgrounded.
    unawaited(
      WakelockPlus.toggle(enable: newState.isPlaying).catchError((_) {}),
    );

    // Update lock screen / notification controls.
    _mediaSession?.updateFromAppState(newState);

    if (newState.isPlaying) {
      _startPositionSave();
    } else {
      _positionSaveTimer?.cancel();
      _updatePlayTime();
      _playStartedAt = null;
      // Save immediately on pause (if threshold met).
      if (_playTimeMs >= _minPlayTimeMs) {
        unawaited(_savePosition());
      }

      // Detect album completion: paused on the last track, within 5s of end.
      // Using a fixed threshold instead of percentage — 90% of a 60-min
      // Hörspiel would cut off 6 minutes of content.
      if (newState.nextTracksCount == 0 &&
          newState.durationMs > 0 &&
          newState.positionMs > newState.durationMs - 5000) {
        unawaited(_onAlbumCompleted());
      }
    }
  }

  /// Mark the current episode heard, then auto-advance if in a series.
  Future<void> _onAlbumCompleted() async {
    await _markAlbumHeard();

    final groupId = state.activeGroupId;
    if (groupId == null) return;

    // Only auto-advance for Hörspiel groups, not music.
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
    _advanceTimer = Timer(const Duration(seconds: 3), () {
      unawaited(playCard(nextCard.id));
    });

    // Signal the UI to show the next episode preview during the delay.
    state = state.copyWith(
      nextEpisodeTitle: nextCard.customTitle ?? nextCard.title,
      nextEpisodeCoverUrl: nextCard.coverUrl,
    );
  }

  /// Cumulative play time for the current card. Reset on card change.
  int _playTimeMs = 0;
  DateTime? _playStartedAt;

  /// Minimum play time before saving position (prevents brief taps from
  /// marking episodes as "in progress").
  static const _minPlayTimeMs = 30000; // 30 seconds

  void _startPositionSave() {
    _positionSaveTimer?.cancel();
    _playStartedAt = DateTime.now();
    // Save every 10 seconds while playing (if threshold met).
    _positionSaveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        _updatePlayTime();
        if (_playTimeMs >= _minPlayTimeMs) {
          unawaited(_savePosition());
        }
      },
    );
  }

  void _updatePlayTime() {
    if (_playStartedAt != null) {
      _playTimeMs += DateTime.now().difference(_playStartedAt!).inMilliseconds;
      _playStartedAt = DateTime.now();
    }
  }

  Future<void> _savePosition() async {
    final cardId = state.activeCardId;
    final track = state.track;
    if (cardId == null || track == null || state.positionMs <= 0) return;

    try {
      final cards = ref.read(tileItemRepositoryProvider);
      await cards.savePosition(
        itemId: cardId,
        trackUri: track.uri,
        trackNumber: state.trackNumber,
        positionMs: state.positionMs,
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Position save failed', exception: e);
    }
  }

  /// Mark the currently-playing album as heard.
  Future<void> _markAlbumHeard() async {
    final cardId = state.activeCardId;
    if (cardId == null) return;

    try {
      final cards = ref.read(tileItemRepositoryProvider);
      final card = await cards.getById(cardId);
      if (card == null || card.isHeard) return;

      await cards.markHeard(card.id);
      Log.info(
        _tag,
        'Album completed',
        data: {
          'cardId': card.id,
          'title': card.title,
        },
      );
    } on Exception catch (e) {
      Log.error(_tag, 'Mark heard failed', exception: e);
    }
  }
}
