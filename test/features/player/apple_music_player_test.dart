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
      // Context-assert: the stream actually emitted at least one
      // state. Without this, `.any()` returns false on an empty
      // list and the second assertion would still pass — meaning
      // the test could pass even if the player never reported the
      // error at all.
      expect(states, isNotEmpty, reason: 'player must emit at least one state');
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
      expect(states, isNotEmpty, reason: 'player must emit at least one state');
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
      expect(states, isNotEmpty, reason: 'player must emit at least one state');
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

      // Context-assert: player landed on track 1 (1-indexed) which
      // is the fallback for out-of-bounds. Without this assertion
      // the test would pass even if the fallback logic landed on
      // an unexpected track that happened to call resolveStream('s1')
      // for an unrelated reason.
      expect(
        player.currentTrackNumber,
        1,
        reason: 'fallback should land on track 1, not the out-of-bounds index',
      );

      // Should resolve track at index 0 (fallback), not 99.
      verify(() => mockResolver.resolveStream('s1')).called(1);
      verifyNever(() => mockResolver.resolveStream('s2'));

      // Verify the correct token and songId were passed to native.
      final captured =
          verify(
            () => mockMusicKit.playDrmStream(
              hlsUrl: captureAny(named: 'hlsUrl'),
              licenseUrl: captureAny(named: 'licenseUrl'),
              developerToken: captureAny(named: 'developerToken'),
              musicUserToken: captureAny(named: 'musicUserToken'),
              songId: captureAny(named: 'songId'),
              startPositionMs: captureAny(named: 'startPositionMs'),
            ),
          ).captured;
      // captured is a flat list: [hlsUrl, licenseUrl, devToken, userToken, songId, startPos]
      expect(captured[0], 'https://example.com/hls');
      expect(captured[1], 'https://example.com/lic');
      expect(captured[2], 'test-dev-token');
      expect(captured[3], 'test-user-token');
      expect(captured[4], 's1');
      expect(captured[5], 0); // fallback to position 0
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

      // Context-assert: the player actually emitted SOMETHING in
      // response to the play() + EventChannel push. Without this,
      // a future bug that breaks state propagation entirely would
      // make `playing` empty and the `expect(playing, isNotEmpty)`
      // would fail with a confusing 'expected non-empty, actual []'
      // — you couldn't tell if play() failed or the EventChannel
      // failed. With this precondition the failure message is
      // clear: 'no states emitted at all'.
      expect(states, isNotEmpty, reason: 'player must emit at least one state');

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
      // Setup: play() creates the DRM subscription lazily, so we
      // need to drive a successful play() to get the subscription
      // attached before we can verify dispose() cancels it.
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

      // Context-assert: the play() call wired up the DRM subscription.
      // Without this baseline a regression where play() forgot to
      // call _listenToDrmState() would still pass the post-dispose
      // hasListener=false check (because there'd never have been a
      // listener in the first place).
      expect(
        drmStateController.hasListener,
        isTrue,
        reason: 'baseline: play() should have subscribed to the DRM stream',
      );

      await player.dispose();

      // The actual contract dispose owes us: it MUST cancel the
      // subscription so the controller no longer has a listener.
      // Without this assertion the original test was a smoke test
      // that passed even if dispose was a no-op or leaked the
      // subscription on every player teardown.
      expect(
        drmStateController.hasListener,
        isFalse,
        reason: 'dispose must release the DRM controller subscription',
      );

      // Adding events after dispose must not throw. (Originally
      // the only thing this test verified — too weak to catch
      // a leaked subscription.)
      drmStateController.add({'type': 'state', 'isPlaying': false});
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
