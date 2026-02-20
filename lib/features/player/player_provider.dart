import 'dart:async' show StreamSubscription, Timer, unawaited;

import 'package:lauschi/core/database/card_repository.dart';
import 'package:lauschi/core/database/group_repository.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/core/spotify/spotify_api.dart';
import 'package:lauschi/core/spotify/spotify_auth_provider.dart';
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
  final bridge =
      SpotifyPlayerBridge()
        // Keep all token consumers in sync when the bridge refreshes tokens.
        ..onTokenRefreshed = (tokens) {
          ref.read(spotifyAuthProvider.notifier).updateTokens(tokens);
        };

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
  Timer? _positionSaveTimer;

  /// URI of the album/context currently being played.
  /// Used to highlight the active card in the grid.
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
      _positionSaveTimer?.cancel();
      _advanceTimer?.cancel();
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

    final auth = ref.read(spotifyAuthClientProvider);
    await _bridge!.init(auth: auth, tokens: authState.tokens);
    Log.info(_tag, 'Bridge initialized');
  }

  /// Play a Spotify URI (album, playlist, or track).
  ///
  /// Uses the Web API to start playback on the WebView SDK device.
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

  /// Pause playback.
  Future<void> pause() async {
    try {
      await _bridge!.togglePlay();
    } on Exception catch (e) {
      Log.error(_tag, 'Pause failed', exception: e);
    }
  }

  /// Resume playback.
  Future<void> resume() async {
    try {
      await _bridge!.togglePlay();
    } on Exception catch (e) {
      Log.error(_tag, 'Resume failed', exception: e);
    }
  }

  /// Toggle play/pause.
  Future<void> togglePlay() async {
    try {
      await _bridge!.togglePlay();
    } on Exception catch (e) {
      Log.error(_tag, 'Toggle failed', exception: e);
    }
  }

  /// Skip to next track.
  Future<void> nextTrack() async {
    try {
      await _bridge!.nextTrack();
    } on Exception catch (e) {
      Log.error(_tag, 'Next track failed', exception: e);
    }
  }

  /// Skip to previous track.
  Future<void> prevTrack() async {
    try {
      await _bridge!.prevTrack();
    } on Exception catch (e) {
      Log.error(_tag, 'Previous track failed', exception: e);
    }
  }

  /// Clear any error state.
  void clearError() {
    // ignore: avoid_redundant_argument_values, null clears the error
    state = state.copyWith(error: null);
  }

  /// Seek to position in milliseconds.
  Future<void> seek(int positionMs) async {
    try {
      await _bridge!.seek(positionMs);
    } on Exception catch (e) {
      Log.error(_tag, 'Seek failed', exception: e);
    }
  }

  /// Resume playback for a card, restoring saved position.
  ///
  /// When [groupId] is set, completing this episode auto-advances to the
  /// next unheard episode in the series.
  Future<void> playCard(String spotifyUri, {String? groupId}) async {
    // Cancel any pending auto-advance and position save timer.
    _advanceTimer?.cancel();
    _positionSaveTimer?.cancel();
    _activeContextUri = spotifyUri;
    _activeGroupId = groupId;
    state = state.copyWith(
      isLoading: true,
      // ignore: avoid_redundant_argument_values, null clears previous error
      error: null,
      clearNextEpisode: true,
    );

    final deviceId = state.deviceId;
    if (deviceId == null || _api == null) {
      Log.error(_tag, 'Cannot play — no device ID');
      state = state.copyWith(
        isLoading: false,
        error: 'Spotify nicht verbunden',
      );
      return;
    }

    final cards = ref.read(cardRepositoryProvider);
    final card = await cards.getByProviderUri(spotifyUri);

    Log.info(
      _tag,
      'Playing card',
      data: {
        'uri': spotifyUri,
        'resumeTrack': card?.lastTrackUri ?? 'none',
        'resumeMs': '${card?.lastPositionMs ?? 0}',
      },
    );

    try {
      // If we have a saved position, resume at that track + offset.
      if (card != null &&
          card.lastTrackUri != null &&
          card.lastPositionMs > 0) {
        await _api!.play(
          spotifyUri,
          deviceId: deviceId,
          offsetUri: card.lastTrackUri,
          positionMs: card.lastPositionMs,
        );
      } else {
        await _api!.play(spotifyUri, deviceId: deviceId);
      }
      state = state.copyWith(isLoading: false);
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
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

      // Detect album completion: paused on the last track, near the end.
      if (newState.nextTracksCount == 0 &&
          newState.durationMs > 0 &&
          newState.positionMs > newState.durationMs * 0.9) {
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
        'nextUri': nextCard.providerUri,
      },
    );

    // Brief pause before advancing so the transition feels intentional.
    _advanceTimer?.cancel();
    _advanceTimer = Timer(const Duration(seconds: 3), () {
      unawaited(playCard(nextCard.providerUri, groupId: _activeGroupId));
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
    final uri = _activeContextUri;
    final track = state.track;
    if (uri == null || track == null || state.positionMs <= 0) return;

    try {
      final cards = ref.read(cardRepositoryProvider);
      final card = await cards.getByProviderUri(uri);
      if (card == null) return;

      await cards.savePosition(
        cardId: card.id,
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
    final uri = _activeContextUri;
    if (uri == null) return;

    try {
      final cards = ref.read(cardRepositoryProvider);
      final card = await cards.getByProviderUri(uri);
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
