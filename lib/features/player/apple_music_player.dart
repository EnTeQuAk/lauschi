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
  String? _albumArtworkUrl;
  int _durationMs = 0;
  int _positionMs = 0;
  bool _isPlaying = false;
  int _trackIndex = 0;
  int _totalTracks = 0;

  // Track metadata for the album.
  final _tracks = <AppleMusicTrack>[];

  /// Guard against spurious trackEnded during manual track transitions.
  bool _isAdvancing = false;

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
    _albumArtworkUrl = trackInfo.artworkUrl;
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

    // Clamp saved track index to valid range. If the album's track list
    // changed since last listen (tracks removed/reordered), fall back to 0.
    final safeIndex = trackIndex < tracks.length ? trackIndex : 0;
    final safePosition = safeIndex == trackIndex ? positionMs : 0;
    _trackIndex = safeIndex;

    // Subscribe to native ExoPlayer state via EventChannel.
    _listenToDrmState();

    // Resolve and play the track.
    await _playTrackAtIndex(safeIndex, positionMs: safePosition);
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
    _isAdvancing = true;
    try {
      await _playTrackAtIndex(_trackIndex + 1);
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> prevTrack() async {
    if (_trackIndex <= 0) return;
    _isAdvancing = true;
    try {
      await _playTrackAtIndex(_trackIndex - 1);
    } finally {
      _isAdvancing = false;
    }
  }

  @override
  Future<void> dispose() async {
    await _drmStateSub?.cancel();
    _drmStateSub = null;
    await _stateController.close();
  }

  Future<void> _advanceToNextTrack() async {
    try {
      await _playTrackAtIndex(_trackIndex + 1);
    } finally {
      _isAdvancing = false;
    }
  }

  // ── Track playback ──────────────────────────────────────────────────

  Future<void> _playTrackAtIndex(int index, {int positionMs = 0}) async {
    if (index < 0 || index >= _tracks.length) return;
    final sw = Stopwatch()..start();

    final track = _tracks[index];
    StreamResolution? resolution;
    try {
      resolution = await _streamResolver.resolveStream(track.id);
      Log.info(
        _tag,
        'Stream resolved',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
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
    _positionMs = 0; // Reset position for the new track.
    _currentTrack = TrackInfo(
      uri: 'apple_music:track:${track.id}',
      name: track.name,
      artist: track.artistName,
      artworkUrl: _albumArtworkUrl,
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
      Log.info(
        _tag,
        'Calling playDrmStream',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
      await _musicKit.playDrmStream(
        hlsUrl: resolution.hlsUrl,
        licenseUrl: resolution.licenseUrl,
        developerToken: _developerToken,
        musicUserToken: _musicUserToken,
        songId: track.id,
        startPositionMs: positionMs,
      );
      Log.info(
        _tag,
        'playDrmStream returned',
        data: {'ms': '${sw.elapsedMilliseconds}'},
      );
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
        // Ignored. Each ExoPlayer instance plays a single MediaItem, so
        // the native index is always 0. Track index is managed on the
        // Dart side via _trackIndex. This event will become useful when
        // we switch to ConcatenatingMediaSource for gapless playback.
        break;

      case 'trackEnded':
        // Guard against spurious STATE_ENDED from ExoPlayer release()
        // during track transitions. When _playTrackAtIndex calls
        // playDrmStream, the old player is released and may fire ENDED.
        if (_isAdvancing) break;

        Log.info(
          _tag,
          'Track ended',
          data: {'index': '$_trackIndex', 'hasNext': '$hasNextTrack'},
        );
        if (hasNextTrack) {
          _isAdvancing = true;
          unawaited(_advanceToNextTrack());
        } else {
          // Last track finished.
          _isPlaying = false;
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
