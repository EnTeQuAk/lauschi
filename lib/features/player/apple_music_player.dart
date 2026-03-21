import 'dart:async';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via just_audio (ExoPlayer) with HLS streams.
///
/// Resolves song IDs to HLS stream URLs via Apple's webPlayback endpoint
/// (same API that music.apple.com uses). ExoPlayer handles HLS playback
/// natively, including any DRM negotiation.
///
/// This avoids both the WebView DRM issue (Widevine L3 CONTENT_EQUIVALENT)
/// and the native MediaPlayerController issue (5+ minute startup delay).
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer({
    required AppleMusicStreamResolver streamResolver,
    required AppleMusicApi api,
  }) : _streamResolver = streamResolver,
       _api = api;

  final AppleMusicStreamResolver _streamResolver;
  final AppleMusicApi _api;

  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<ja.PlayerState>? _playerStateSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<int?>? _indexSub;

  ja.AudioPlayer? _player;

  TrackInfo? _currentTrack;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _totalTracks = 0;

  DateTime _lastPositionEmit = DateTime(0);

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  int get currentPositionMs => _positionMs;

  @override
  int get currentTrackNumber => _trackIndex + 1;

  @override
  bool get hasNextTrack => _trackIndex < _totalTracks - 1;

  /// Play an album starting from a track index.
  Future<void> play({
    required String albumId,
    required TrackInfo trackInfo,
    int trackIndex = 0,
    int positionMs = 0,
  }) async {
    _currentTrack = trackInfo;
    Log.info(
      _tag,
      'Playing',
      data: {'albumId': albumId, 'track': '$trackIndex'},
    );

    // Fetch album tracks to get individual song IDs.
    final tracks = await _api.getAlbumTracks(albumId);
    if (tracks.isEmpty) {
      Log.warn(_tag, 'No tracks found for album $albumId');
      _emitState(error: PlayerError.contentUnavailable);
      return;
    }

    _totalTracks = tracks.length;
    _trackIndex = trackIndex;

    // Resolve HLS stream URLs for all tracks.
    final sources = <ja.AudioSource>[];
    for (final track in tracks) {
      final streamUrl = await _streamResolver.resolveStreamUrl(track.id);
      if (streamUrl != null) {
        sources.add(
          ja.AudioSource.uri(
            Uri.parse(streamUrl),
            tag: _TrackTag(
              id: track.id,
              name: track.name,
              artistName: track.artistName,
              durationMs: track.durationMs,
            ),
          ),
        );
      } else {
        Log.warn(_tag, 'Could not resolve stream for track ${track.id}');
      }
    }

    if (sources.isEmpty) {
      Log.warn(_tag, 'No playable streams resolved');
      _emitState(error: PlayerError.playbackFailed);
      return;
    }

    // Create player with concatenating source (album as playlist).
    final player = ja.AudioPlayer();
    _player = player;
    _listenToPlayer(player);

    try {
      final playlist = ja.ConcatenatingAudioSource(children: sources);
      await player.setAudioSource(
        playlist,
        initialIndex: trackIndex,
        initialPosition:
            positionMs > 0 ? Duration(milliseconds: positionMs) : Duration.zero,
      );
      await player.play();
    } on ja.PlayerException catch (e) {
      Log.error(
        _tag,
        'Player error',
        data: {'code': '${e.code}', 'message': e.message ?? ''},
      );
      _emitState(error: PlayerError.playbackFailed);
    } on Exception catch (e) {
      Log.error(_tag, 'Play failed', exception: e);
      _emitState(error: PlayerError.playbackFailed);
    }
  }

  @override
  Future<void> resume() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> stop() async => _player?.stop();

  @override
  Future<void> seek(int positionMs) async =>
      _player?.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> nextTrack() async {
    if (_player != null && hasNextTrack) {
      await _player!.seekToNext();
    }
  }

  @override
  Future<void> prevTrack() async {
    if (_player != null) {
      await _player!.seekToPrevious();
    }
  }

  @override
  Future<void> dispose() async {
    await _playerStateSub?.cancel();
    await _durationSub?.cancel();
    await _positionSub?.cancel();
    await _indexSub?.cancel();
    await _player?.dispose();
    _player = null;
    await _stateController.close();
  }

  // ── Player listeners ────────────────────────────────────────────────

  void _listenToPlayer(ja.AudioPlayer player) {
    _playerStateSub = player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      if (state.processingState == ja.ProcessingState.completed) {
        Log.info(_tag, 'Playback completed');
        _isPlaying = false;
      }
      _emitState();
    });

    _durationSub = player.durationStream.listen((duration) {
      _durationMs = duration?.inMilliseconds ?? 0;
      _emitState();
    });

    _positionSub = player.positionStream.listen((position) {
      _positionMs = position.inMilliseconds;
      final now = DateTime.now();
      if (now.difference(_lastPositionEmit).inMilliseconds >= 1000) {
        _lastPositionEmit = now;
        _emitState();
      }
    });

    _indexSub = player.currentIndexStream.listen((index) {
      if (index != null && index != _trackIndex) {
        _trackIndex = index;
        // Update track info from the tag.
        final tag = player.sequenceState?.currentSource?.tag;
        if (tag is _TrackTag) {
          _currentTrack = TrackInfo(
            uri: 'apple_music:track:${tag.id}',
            name: tag.name,
            artist: tag.artistName,
          );
          _durationMs = tag.durationMs;
          Log.info(
            _tag,
            'Track changed',
            data: {
              'track': tag.name,
              'index': '$_trackIndex',
              'total': '$_totalTracks',
            },
          );
        }
        _emitState();
      }
    });
  }

  void _emitState({PlayerError? error}) {
    if (_stateController.isClosed) return;
    _stateController.add(
      PlaybackState(
        isPlaying: _isPlaying,
        isReady: true,
        track: _currentTrack,
        positionMs: _positionMs,
        durationMs: _durationMs,
        error: error,
      ),
    );
  }
}

/// Metadata tag attached to each audio source in the playlist.
class _TrackTag {
  const _TrackTag({
    required this.id,
    required this.name,
    this.artistName,
    this.durationMs = 0,
  });

  final String id;
  final String name;
  final String? artistName;
  final int durationMs;
}
