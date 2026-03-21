import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/apple_music_player.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:mocktail/mocktail.dart';
import 'package:music_kit/music_kit.dart';

class MockMusicKit extends Mock implements MusicKit {}

void main() {
  group('AppleMusicPlayer', () {
    late MockMusicKit mockMusicKit;
    late AppleMusicPlayer player;

    setUp(() {
      mockMusicKit = MockMusicKit();
      when(
        () => mockMusicKit.onMusicPlayerStateChanged,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => mockMusicKit.onPlayerQueueChanged,
      ).thenAnswer((_) => const Stream.empty());
      player = AppleMusicPlayer(mockMusicKit);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('initial state: not playing, position 0', () {
      expect(player.currentPositionMs, 0);
      expect(player.currentTrackNumber, 1);
      expect(player.hasNextTrack, false);
    });

    test('pause delegates to native SDK', () async {
      when(() => mockMusicKit.pause()).thenAnswer((_) async {});
      await player.pause();
      verify(() => mockMusicKit.pause()).called(1);
    });

    test('resume delegates to native SDK', () async {
      when(() => mockMusicKit.play()).thenAnswer((_) async {});
      await player.resume();
      verify(() => mockMusicKit.play()).called(1);
    });

    test('stop delegates to native SDK', () async {
      when(() => mockMusicKit.stop()).thenAnswer((_) async {});
      await player.stop();
      verify(() => mockMusicKit.stop()).called(1);
    });

    test('seek converts ms to seconds', () async {
      when(() => mockMusicKit.setPlaybackTime(any())).thenAnswer((_) async {});
      await player.seek(30000);
      verify(() => mockMusicKit.setPlaybackTime(30.0)).called(1);
    });

    test('nextTrack delegates to native SDK', () async {
      when(() => mockMusicKit.skipToNextEntry()).thenAnswer((_) async {});
      await player.nextTrack();
      verify(() => mockMusicKit.skipToNextEntry()).called(1);
    });

    test('prevTrack delegates to native SDK', () async {
      when(() => mockMusicKit.skipToPreviousEntry()).thenAnswer((_) async {});
      await player.prevTrack();
      verify(() => mockMusicKit.skipToPreviousEntry()).called(1);
    });

    test('play calls setQueue with album type', () async {
      when(
        () => mockMusicKit.setQueue(
          any(),
          item: any(named: 'item'),
          autoplay: any(named: 'autoplay'),
        ),
      ).thenAnswer((_) async {});

      await player.play(
        albumId: 'test-album-123',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test Track'),
      );

      verify(
        () => mockMusicKit.setQueue(
          'albums',
          item: {'id': 'test-album-123'},
          autoplay: true,
        ),
      ).called(1);
    });

    test('play with positionMs seeks after delay', () async {
      when(
        () => mockMusicKit.setQueue(
          any(),
          item: any(named: 'item'),
          autoplay: any(named: 'autoplay'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockMusicKit.setPlaybackTime(any())).thenAnswer((_) async {});

      await player.play(
        albumId: 'test-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test Track'),
        positionMs: 45000,
      );

      // Seek happens after a 1s delay.
      await Future<void>.delayed(const Duration(seconds: 2));
      verify(() => mockMusicKit.setPlaybackTime(45.0)).called(1);
    });

    test('dispose cancels subscriptions', () async {
      // Should not throw.
      await player.dispose();
    });
  });
}
