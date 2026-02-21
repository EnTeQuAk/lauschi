import 'dart:async' show StreamSubscription, Timer, unawaited;

import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
import 'package:lauschi/features/player/direct_player.dart';
import 'package:lauschi/features/player/media_session_handler.dart';
import 'package:lauschi/features/player/player_state.dart';
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
  StreamSubscription<PlaybackState>? _directSubscription;
  Timer? _positionSaveTimer;
  DirectPlayer? _directPlayer;

  /// ID of the card currently being played.
  String? _activeCardId;
  String? get activeCardId => _activeCardId;

  /// URI of the album/context currently being played.
  /// Used to highlight the active card in the grid and for position saving.
  String? _activeContextUri;
  String? get activeContextUri => _activeContextUri;

  /// Group ID for auto-advance. When set, completing an episode
  /// auto-plays the next unheard episode in the series.
  String? _activeGroupId;
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
      unawaited(_directSubscription?.cancel());
      _positionSaveTimer?.cancel();
      _advanceTimer?.cancel();
      unawaited(_directPlayer?.dispose());
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
  /// and resume state. This method does not set [_activeCardId], so position
  /// saving and mark-heard will not work.
  @Deprecated('Use playCard(cardId) instead')
  Future<void> play(String spotifyUri) async {
    final deviceId = state.deviceId;
    if (deviceId == null || _api == null) {
      Log.error(_tag, 'Cannot play — no device ID');
      return;
    }

    _activeContextUri = spotifyUri;
    Log.info(_tag, 'Playing', data: {'uri': spotifyUri});

    try {
      await _api!.play(spotifyUri, deviceId: deviceId);
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
    }
  }

  /// Whether the currently active card uses direct playback (non-SDK).
  bool get _isDirectPlayback => _directPlayer != null && _activeCardId != null;

  /// Pause playback (idempotent — safe to call when already paused).
  Future<void> pause() async {
    _advanceTimer?.cancel();
    if (_isDirectPlayback) {
      await _directPlayer!.pause();
    } else {
      await _bridgeCommand('pause', () => _bridge!.pause());
    }
  }

  /// Resume playback (idempotent — safe to call when already playing).
  Future<void> resume() async {
    if (_isDirectPlayback) {
      await _directPlayer!.resume();
    } else {
      await _bridgeCommand('resume', () => _bridge!.resume());
    }
  }

  /// Toggle play/pause.
  Future<void> togglePlay() async {
    _advanceTimer?.cancel();
    if (_isDirectPlayback) {
      if (state.isPlaying) {
        await _directPlayer!.pause();
      } else {
        await _directPlayer!.resume();
      }
    } else {
      await _bridgeCommand('toggle', () => _bridge!.togglePlay());
    }
  }

  /// Skip to next track. For direct playback (single-file), this is a no-op.
  Future<void> nextTrack() async {
    if (!_isDirectPlayback) {
      await _bridgeCommand('next', () => _bridge!.nextTrack());
    }
  }

  /// Skip to previous track. For direct playback (single-file), this is a no-op.
  Future<void> prevTrack() async {
    if (!_isDirectPlayback) {
      await _bridgeCommand('prev', () => _bridge!.prevTrack());
    }
  }

  /// Clear any error state.
  void clearError() {
    _advanceTimer?.cancel();
    // ignore: avoid_redundant_argument_values, null clears the error
    state = state.copyWith(error: null);
  }

  /// Seek to position in milliseconds.
  Future<void> seek(int positionMs) async {
    if (_isDirectPlayback) {
      await _directPlayer?.seek(positionMs);
    } else {
      await _bridgeCommand('seek', () => _bridge!.seek(positionMs));
    }
  }

  /// Execute a bridge command with error handling and device recovery.
  ///
  /// If the bridge isn't ready, reconnects and retries once.
  Future<void> _bridgeCommand(
    String name,
    Future<void> Function() command,
  ) async {
    if (_bridge == null) return;
    try {
      await command();
    } on Exception catch (e) {
      Log.error(_tag, '$name failed, attempting reconnect', exception: e);
      try {
        await _bridge!.reconnect();
        await command();
      } on Exception catch (retryError) {
        Log.error(_tag, '$name retry failed', exception: retryError);
        state = state.copyWith(error: 'Steuerung fehlgeschlagen');
      }
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

    final cards = ref.read(cardRepositoryProvider);
    final card = await cards.getById(cardId);
    if (card == null) {
      Log.error(_tag, 'Card not found', data: {'cardId': cardId});
      return;
    }

    // Check content expiration before attempting playback.
    if (card.availableUntil != null &&
        card.availableUntil!.isBefore(DateTime.now())) {
      // Don't set _activeCardId — prevents stale state from leaking into
      // position saves or mark-heard operations.
      state = state.copyWith(
        error: 'Diese Geschichte ist leider nicht mehr verfügbar',
      );
      return;
    }

    // Set active state only after validation passes.
    _activeCardId = cardId;
    _activeContextUri = card.providerUri;
    _activeGroupId = card.groupId;
    state = state.copyWith(
      isLoading: true,
      // ignore: avoid_redundant_argument_values, null clears previous error
      error: null,
      clearNextEpisode: true,
    );

    // Stop the other player backend before switching. Prevents dual playback
    // and stale state from the previous backend bleeding into position saves.
    if (card.provider != 'spotify') {
      await _directPlayer?.stop();
    }
    if (card.provider == 'spotify') {
      // Clear direct player reference so _isDirectPlayback returns false.
      unawaited(_directSubscription?.cancel());
      _directSubscription = null;
      await _directPlayer?.stop();
      _directPlayer = null;
    }

    switch (card.provider) {
      case 'spotify':
        await _playSpotify(card);
      case 'ard_audiothek':
        await _playDirect(card);
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
  Future<void> _playSpotify(db.AudioCard card) async {
    final deviceId = state.deviceId;
    if (deviceId == null || _api == null) {
      Log.error(_tag, 'Cannot play — no device ID');
      state = state.copyWith(
        isLoading: false,
        error: 'Spotify nicht verbunden',
      );
      return;
    }

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
      await _bridge!.reconnect();
      final newDeviceId = await _bridge!.waitForDevice();
      if (newDeviceId != null) {
        try {
          await _playOnDevice(card.providerUri, newDeviceId, card);
          state = state.copyWith(isLoading: false);
        } on Exception catch (e) {
          Log.error(_tag, 'Retry after reconnect failed', exception: e);
          state = state.copyWith(
            isLoading: false,
            error: 'Wiedergabe fehlgeschlagen',
          );
        }
      } else {
        Log.error(_tag, 'Reconnect timed out — no device');
        state = state.copyWith(
          isLoading: false,
          error: 'Spotify-Verbindung verloren',
        );
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
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
    db.AudioCard? card,
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
  Future<void> _playDirect(db.AudioCard card) async {
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

    _directPlayer ??= DirectPlayer();

    // Subscribe to direct player state (replaces Spotify bridge events).
    unawaited(_directSubscription?.cancel());
    _directSubscription = _directPlayer!.stateStream.listen((directState) {
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
      await _directPlayer!.play(
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
    unawaited(WakelockPlus.toggle(enable: newState.isPlaying));

    // Update lock screen / notification controls.
    _mediaSession?.updateFromAppState(newState);

    if (newState.isPlaying) {
      _startPositionSave();
    } else {
      _positionSaveTimer?.cancel();
      // Save immediately on pause
      unawaited(_savePosition());

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

    if (_activeGroupId == null) return;

    // Only auto-advance for Hörspiel groups, not music.
    final groups = ref.read(groupRepositoryProvider);
    final group = await groups.getById(_activeGroupId!);
    if (group == null || group.contentType != 'hoerspiel') return;

    final nextCard = await groups.nextUnheard(_activeGroupId!);

    if (nextCard == null) {
      Log.info(_tag, 'Series finished — no more episodes');
      return;
    }

    Log.info(
      _tag,
      'Auto-advance',
      data: {
        'groupId': _activeGroupId!,
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

  void _startPositionSave() {
    _positionSaveTimer?.cancel();
    // Save every 10 seconds while playing
    _positionSaveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_savePosition()),
    );
  }

  Future<void> _savePosition() async {
    final cardId = _activeCardId;
    final track = state.track;
    if (cardId == null || track == null || state.positionMs <= 0) return;

    try {
      final cards = ref.read(cardRepositoryProvider);
      await cards.savePosition(
        cardId: cardId,
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
    final cardId = _activeCardId;
    if (cardId == null) return;

    try {
      final cards = ref.read(cardRepositoryProvider);
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
