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
  Timer? _positionTimer;

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

    _tracks.clear();
    _tracks.addAll(tracks);
    _totalTracks = tracks.length;
    _trackIndex = trackIndex;

    // Resolve the first track's stream to get the HLS URL + license URL.
    final firstTrack = tracks[trackIndex];
    final streamUrl = await _streamResolver.resolveStreamUrl(firstTrack.id);
    final licenseUrl = _streamResolver.lastLicenseUrl ?? '';

    if (streamUrl == null) {
      Log.warn(_tag, 'Could not resolve stream for track ${firstTrack.id}');
      _emitState(error: PlayerError.playbackFailed);
      return;
    }

    Log.info(
      _tag,
      'Starting DRM playback',
      data: {
        'track': firstTrack.name,
        'licenseUrl': licenseUrl.isNotEmpty ? 'yes' : 'no',
      },
    );

    // Update track info.
    _currentTrack = TrackInfo(
      uri: 'apple_music:track:${firstTrack.id}',
      name: firstTrack.name,
      artist: firstTrack.artistName,
    );
    _durationMs = firstTrack.durationMs;

    try {
      await _musicKit.playDrmStream(
        hlsUrl: streamUrl,
        licenseUrl: licenseUrl,
        developerToken: _developerToken,
        musicUserToken: _musicUserToken,
      );
      _isPlaying = true;
      _startPositionPolling();
      _emitState();
    } on Exception catch (e) {
      Log.error(_tag, 'DRM playback failed', exception: e);
      _emitState(error: PlayerError.playbackFailed);
    }
  }

  @override
  Future<void> resume() async {
    await _musicKit.drmResume();
    _isPlaying = true;
    _startPositionPolling();
    _emitState();
  }

  @override
  Future<void> pause() async {
    await _musicKit.drmPause();
    _isPlaying = false;
    _stopPositionPolling();
    _emitState();
  }

  @override
  Future<void> stop() async {
    await _musicKit.drmStop();
    _isPlaying = false;
    _stopPositionPolling();
    _emitState();
  }

  @override
  Future<void> seek(int positionMs) async {
    await _musicKit.drmSeek(positionMs);
    _positionMs = positionMs;
    _emitState();
  }

  @override
  Future<void> nextTrack() async {
    // For now, resolve and play the next track individually.
    // TODO(#231): use ExoPlayer ConcatenatingMediaSource for gapless playback
    if (!hasNextTrack) return;
    _trackIndex++;
    final track = _tracks[_trackIndex];
    final streamUrl = await _streamResolver.resolveStreamUrl(track.id);
    if (streamUrl == null) return;

    _currentTrack = TrackInfo(
      uri: 'apple_music:track:${track.id}',
      name: track.name,
      artist: track.artistName,
    );
    _durationMs = track.durationMs;

    await _musicKit.playDrmStream(
      hlsUrl: streamUrl,
      licenseUrl: _streamResolver.lastLicenseUrl ?? '',
      developerToken: _developerToken,
      musicUserToken: _musicUserToken,
    );
    _isPlaying = true;
    _emitState();
  }

  @override
  Future<void> prevTrack() async {
    if (_trackIndex <= 0) return;
    _trackIndex--;
    final track = _tracks[_trackIndex];
    final streamUrl = await _streamResolver.resolveStreamUrl(track.id);
    if (streamUrl == null) return;

    _currentTrack = TrackInfo(
      uri: 'apple_music:track:${track.id}',
      name: track.name,
      artist: track.artistName,
    );
    _durationMs = track.durationMs;

    await _musicKit.playDrmStream(
      hlsUrl: streamUrl,
      licenseUrl: _streamResolver.lastLicenseUrl ?? '',
      developerToken: _developerToken,
      musicUserToken: _musicUserToken,
    );
    _isPlaying = true;
    _emitState();
  }

  @override
  Future<void> dispose() async {
    _stopPositionPolling();
    await _stateController.close();
  }

  // ── Position polling ────────────────────────────────────────────────

  void _startPositionPolling() {
    _stopPositionPolling();
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_pollPosition()),
    );
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _pollPosition() async {
    try {
      _positionMs = await _musicKit.drmPosition;
      final dur = await _musicKit.drmDuration;
      if (dur > 0) _durationMs = dur;
      _emitState();
    } on Exception {
      // Player might not be ready.
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
