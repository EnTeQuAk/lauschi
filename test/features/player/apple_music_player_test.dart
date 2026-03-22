import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/features/player/apple_music_player.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:mocktail/mocktail.dart';
import 'package:music_kit/music_kit.dart';

class MockStreamResolver extends Mock implements AppleMusicStreamResolver {}

class MockAppleMusicApi extends Mock implements AppleMusicApi {}

class MockMusicKit extends Mock implements MusicKit {}

const _twoTracks = [
  AppleMusicTrack(id: 's1', name: 'Teil 1', trackNumber: 1, durationMs: 90000),
  AppleMusicTrack(id: 's2', name: 'Teil 2', trackNumber: 2, durationMs: 85000),
];

void main() {
  group('AppleMusicPlayer', () {
    late MockStreamResolver mockResolver;
    late MockAppleMusicApi mockApi;
    late MockMusicKit mockMusicKit;
    late StreamController<Map<String, dynamic>> drmStateController;
    late AppleMusicPlayer player;

    setUp(() {
      mockResolver = MockStreamResolver();
      mockApi = MockAppleMusicApi();
      mockMusicKit = MockMusicKit();
      drmStateController = StreamController<Map<String, dynamic>>.broadcast();

      when(
        () => mockMusicKit.drmPlayerStateStream,
      ).thenAnswer((_) => drmStateController.stream);
      when(
        () => mockMusicKit.playDrmStream(
          hlsUrl: any(named: 'hlsUrl'),
          licenseUrl: any(named: 'licenseUrl'),
          developerToken: any(named: 'developerToken'),
          musicUserToken: any(named: 'musicUserToken'),
          songId: any(named: 'songId'),
          startPositionMs: any(named: 'startPositionMs'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockMusicKit.drmPause()).thenAnswer((_) async {});
      when(() => mockMusicKit.drmResume()).thenAnswer((_) async {});
      when(() => mockMusicKit.drmStop()).thenAnswer((_) async {});
      when(() => mockMusicKit.drmSeek(any())).thenAnswer((_) async {});

      player = AppleMusicPlayer(
        streamResolver: mockResolver,
        api: mockApi,
        musicKit: mockMusicKit,
        developerToken: 'test-dev-token',
        musicUserToken: 'test-user-token',
      );
    });

    tearDown(() async {
      await player.dispose();
      await drmStateController.close();
    });

    test('initial state: not playing, position 0', () {
      expect(player.currentPositionMs, 0);
      expect(player.currentTrackNumber, 1);
      expect(player.hasNextTrack, false);
    });

    test('play with empty tracks emits content unavailable', () async {
      when(() => mockApi.getAlbumTracks(any())).thenAnswer((_) async => []);

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      await player.play(
        albumId: 'empty-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        states.any((s) => s.error == PlayerError.contentUnavailable),
        true,
      );
    });

    test('play with unresolvable stream emits playbackFailed', () async {
      when(
        () => mockApi.getAlbumTracks(any()),
      ).thenAnswer((_) async => _twoTracks);
      when(
        () => mockResolver.resolveStream(any()),
      ).thenAnswer((_) async => null);

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states.any((s) => s.error == PlayerError.playbackFailed), true);
    });

    test('play with auth expiry emits appleMusicAuthExpired', () async {
      when(
        () => mockApi.getAlbumTracks(any()),
      ).thenAnswer((_) async => _twoTracks);
      when(
        () => mockResolver.resolveStream(any()),
      ).thenThrow(const AppleMusicAuthExpiredException('token expired'));

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        states.any((s) => s.error == PlayerError.appleMusicAuthExpired),
        true,
      );
    });

    test('play with out-of-bounds trackIndex falls back to 0', () async {
      when(
        () => mockApi.getAlbumTracks(any()),
      ).thenAnswer((_) async => _twoTracks);
      when(() => mockResolver.resolveStream('s1')).thenAnswer(
        (_) async => const StreamResolution(
          hlsUrl: 'https://example.com/hls',
          licenseUrl: 'https://example.com/lic',
        ),
      );

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
        trackIndex: 99, // Out of bounds for 2 tracks
      );

      // Should resolve track at index 0, not 99.
      verify(() => mockResolver.resolveStream('s1')).called(1);
      verifyNever(() => mockResolver.resolveStream('s2'));
    });

    test('prevTrack at index 0 is a no-op', () async {
      when(
        () => mockApi.getAlbumTracks(any()),
      ).thenAnswer((_) async => _twoTracks);
      when(() => mockResolver.resolveStream('s1')).thenAnswer(
        (_) async => const StreamResolution(
          hlsUrl: 'https://example.com/hls',
          licenseUrl: 'https://example.com/lic',
        ),
      );

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      await player.prevTrack();

      // Should NOT call playDrmStream again (already called once in play).
      verify(
        () => mockMusicKit.playDrmStream(
          hlsUrl: any(named: 'hlsUrl'),
          licenseUrl: any(named: 'licenseUrl'),
          developerToken: any(named: 'developerToken'),
          musicUserToken: any(named: 'musicUserToken'),
          songId: any(named: 'songId'),
          startPositionMs: any(named: 'startPositionMs'),
        ),
      ).called(1); // Only the initial play.
    });

    test('EventChannel state updates position and playing', () async {
      when(
        () => mockApi.getAlbumTracks(any()),
      ).thenAnswer((_) async => _twoTracks);
      when(() => mockResolver.resolveStream('s1')).thenAnswer(
        (_) async => const StreamResolution(
          hlsUrl: 'https://example.com/hls',
          licenseUrl: 'https://example.com/lic',
        ),
      );

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      // Simulate ExoPlayer state push.
      drmStateController.add({
        'type': 'state',
        'isPlaying': true,
        'positionMs': 5000,
        'durationMs': 90000,
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final playing = states.where((s) => s.isPlaying).toList();
      expect(playing, isNotEmpty);
      expect(playing.last.positionMs, 5000);
      expect(playing.last.durationMs, 90000);
    });

    test('nextTrack at last track is a no-op', () async {
      when(() => mockApi.getAlbumTracks(any())).thenAnswer(
        (_) async => [_twoTracks.first], // Only 1 track = no next.
      );
      when(() => mockResolver.resolveStream('s1')).thenAnswer(
        (_) async => const StreamResolution(
          hlsUrl: 'https://example.com/hls',
          licenseUrl: 'https://example.com/lic',
        ),
      );

      await player.play(
        albumId: 'album-1',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      expect(player.hasNextTrack, false);
      await player.nextTrack();

      // playDrmStream called only once (initial play, not a second time).
      verify(
        () => mockMusicKit.playDrmStream(
          hlsUrl: any(named: 'hlsUrl'),
          licenseUrl: any(named: 'licenseUrl'),
          developerToken: any(named: 'developerToken'),
          musicUserToken: any(named: 'musicUserToken'),
          songId: any(named: 'songId'),
          startPositionMs: any(named: 'startPositionMs'),
        ),
      ).called(1);
    });

    test('dispose cancels DRM state subscription', () async {
      await player.dispose();
      // Adding events after dispose should not throw.
      drmStateController.add({'type': 'state', 'isPlaying': false});
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
