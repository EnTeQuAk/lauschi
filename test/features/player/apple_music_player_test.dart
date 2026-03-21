import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_stream_resolver.dart';
import 'package:lauschi/features/player/apple_music_player.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:mocktail/mocktail.dart';

class MockStreamResolver extends Mock implements AppleMusicStreamResolver {}

class MockAppleMusicApi extends Mock implements AppleMusicApi {}

void main() {
  group('AppleMusicPlayer', () {
    late MockStreamResolver mockResolver;
    late MockAppleMusicApi mockApi;
    late AppleMusicPlayer player;

    setUp(() {
      mockResolver = MockStreamResolver();
      mockApi = MockAppleMusicApi();
      player = AppleMusicPlayer(
        streamResolver: mockResolver,
        api: mockApi,
      );
    });

    tearDown(() async {
      await player.dispose();
    });

    test('initial state: not playing, position 0', () {
      expect(player.currentPositionMs, 0);
      expect(player.currentTrackNumber, 1);
      expect(player.hasNextTrack, false);
    });

    test('play resolves tracks and streams', () async {
      when(() => mockApi.getAlbumTracks(any())).thenAnswer(
        (_) async => [
          const AppleMusicTrack(
            id: 'song-1',
            name: 'Track 1',
            trackNumber: 1,
            durationMs: 60000,
          ),
        ],
      );
      when(() => mockResolver.resolveStreamUrl('song-1')).thenAnswer(
        (_) async => null, // No stream URL = playback error
      );

      await player.play(
        albumId: 'test-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      verify(() => mockApi.getAlbumTracks('test-album')).called(1);
      verify(() => mockResolver.resolveStreamUrl('song-1')).called(1);
    });

    test('play with empty tracks emits content unavailable', () async {
      when(() => mockApi.getAlbumTracks(any())).thenAnswer(
        (_) async => [],
      );

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      await player.play(
        albumId: 'empty-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states.any((s) => s.error != null), isTrue);
    });

    test('dispose completes cleanly', () async {
      await player.dispose();
    });
  });
}
