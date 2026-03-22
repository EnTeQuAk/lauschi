import 'dart:async';

import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/core/log.dart';
import 'package:lauschi/features/player/player_backend.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:music_kit/music_kit.dart';

const _tag = 'AppleMusicPlayer';

/// Plays Apple Music content via ExoPlayer with Widevine DRM.
///
/// Resolves song IDs to HLS stream URLs via Apple's webPlayback endpoint,
/// then plays them through a native ExoPlayer configured with Widevine
/// DRM and Apple's license server. The HLS playlist method tag is rewritten
/// from ISO-23001-7 to SAMPLE-AES-CTR so ExoPlayer's parser can handle it.
///
/// State updates come via EventChannel (push from native ExoPlayer), not
/// via polling. This gives real-time position, immediate seek feedback,
/// and proper track completion detection.
class AppleMusicPlayer extends PlayerBackend {
  AppleMusicPlayer({
    required AppleMusicStreamResolver streamResolver,
    required AppleMusicApi api,
    required MusicKit musicKit,
    required String developerToken,
    required String musicUserToken,
  }) : _streamResolver = streamResolver,
       _api = api,
       _musicKit = musicKit,
       _developerToken = developerToken,
       _musicUserToken = musicUserToken;

  final AppleMusicStreamResolver _streamResolver;
  final AppleMusicApi _api;
  final MusicKit _musicKit;
  final String _developerToken;
  final String _musicUserToken;

  final _stateController = StreamController<PlaybackState>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _drmStateSub;

  TrackInfo? _currentTrack;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _totalTracks = 0;

  // Track metadata for the album.
  final _tracks = <AppleMusicTrack>[];

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

    _tracks
      ..clear()
      ..addAll(tracks);
    _totalTracks = tracks.length;
    _trackIndex = trackIndex;

    // Subscribe to native ExoPlayer state via EventChannel.
    _listenToDrmState();

    // Resolve and play the first track.
    await _playTrackAtIndex(trackIndex, positionMs: positionMs);
  }

  @override
  Future<void> resume() => _musicKit.drmResume();

  @override
  Future<void> pause() => _musicKit.drmPause();

  @override
  Future<void> stop() => _musicKit.drmStop();

  @override
  Future<void> seek(int positionMs) async {
    await _musicKit.drmSeek(positionMs);
    // Don't optimistically update _positionMs here.
    // The EventChannel will push the confirmed position from ExoPlayer.
  }

  @override
  Future<void> nextTrack() async {
    // TODO(#231): use ExoPlayer ConcatenatingMediaSource for gapless playback
    if (!hasNextTrack) return;
    await _playTrackAtIndex(_trackIndex + 1);
  }

  @override
  Future<void> prevTrack() async {
    if (_trackIndex <= 0) return;
    await _playTrackAtIndex(_trackIndex - 1);
  }

  @override
  Future<void> dispose() async {
    await _drmStateSub?.cancel();
    _drmStateSub = null;
    await _stateController.close();
  }

  // ── Track playback ──────────────────────────────────────────────────

  Future<void> _playTrackAtIndex(int index, {int positionMs = 0}) async {
    if (index < 0 || index >= _tracks.length) return;

    final track = _tracks[index];
    StreamResolution? resolution;
    try {
      resolution = await _streamResolver.resolveStream(track.id);
    } on AppleMusicAuthExpiredException catch (e) {
      Log.warn(
        _tag,
        'Auth expired during stream resolve',
        data: {'error': '$e'},
      );
      _emitState(error: PlayerError.appleMusicAuthExpired);
      return;
    }
    if (resolution == null) {
      Log.warn(_tag, 'Could not resolve stream for track ${track.id}');
      _emitState(error: PlayerError.playbackFailed);
      return;
    }

    _trackIndex = index;
    _currentTrack = TrackInfo(
      uri: 'apple_music:track:${track.id}',
      name: track.name,
      artist: track.artistName,
    );
    _durationMs = track.durationMs;

    Log.info(
      _tag,
      'Starting DRM playback',
      data: {
        'track': track.name,
        'licenseUrl': resolution.licenseUrl.isNotEmpty ? 'yes' : 'no',
      },
    );

    try {
      await _musicKit.playDrmStream(
        hlsUrl: resolution.hlsUrl,
        licenseUrl: resolution.licenseUrl,
        developerToken: _developerToken,
        musicUserToken: _musicUserToken,
        songId: track.id,
        startPositionMs: positionMs,
      );
      // Don't set _isPlaying = true here. The EventChannel will push
      // the confirmed playing state from ExoPlayer.
    } on Exception catch (e) {
      Log.error(_tag, 'DRM playback failed', exception: e);
      _isPlaying = false;
      _emitState(error: PlayerError.playbackFailed);
    }
  }

  // ── Native state stream ─────────────────────────────────────────────

  void _listenToDrmState() {
    unawaited(_drmStateSub?.cancel());
    _drmStateSub = _musicKit.drmPlayerStateStream.listen(
      _onDrmStateEvent,
      onError: (Object error) {
        Log.error(_tag, 'DRM state stream error', data: {'error': '$error'});
      },
    );
  }

  void _onDrmStateEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;

    switch (type) {
      case 'state':
        final isPlaying = event['isPlaying'] as bool? ?? false;
        final posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
        final durMs = (event['durationMs'] as num?)?.toInt() ?? 0;

        _isPlaying = isPlaying;
        _positionMs = posMs;
        if (durMs > 0) _durationMs = durMs;
        _emitState();

      case 'error':
        final message = event['message'] as String? ?? 'Unknown error';
        Log.error(_tag, 'DRM player error', data: {'message': message});
        _isPlaying = false;
        _emitState(error: PlayerError.playbackFailed);

      case 'trackChanged':
        final index = (event['index'] as num?)?.toInt() ?? 0;
        if (index != _trackIndex && index < _tracks.length) {
          _trackIndex = index;
          final track = _tracks[index];
          _currentTrack = TrackInfo(
            uri: 'apple_music:track:${track.id}',
            name: track.name,
            artist: track.artistName,
          );
          _durationMs = track.durationMs;
          Log.info(
            _tag,
            'Track changed',
            data: {
              'track': track.name,
              'index': '$_trackIndex',
              'total': '$_totalTracks',
            },
          );
          _emitState();
        }
    }
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
