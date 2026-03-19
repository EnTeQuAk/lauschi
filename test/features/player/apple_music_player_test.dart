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
      // Stub stop() for dispose().
      when(() => mockMusicKit.stop()).thenAnswer((_) async {});
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

    test('stateStream emits on MusicKit state changes', () async {
      final stateController = StreamController<MusicPlayerState>.broadcast();
      final queueController = StreamController<MusicPlayerQueue>.broadcast();

      when(() => mockMusicKit.onMusicPlayerStateChanged)
          .thenAnswer((_) => stateController.stream);
      when(() => mockMusicKit.onPlayerQueueChanged)
          .thenAnswer((_) => queueController.stream);
      when(() => mockMusicKit.setQueue(any(), item: any(named: 'item')))
          .thenAnswer((_) async {});
      when(() => mockMusicKit.play()).thenAnswer((_) async {});
      when(() => mockMusicKit.playbackTime).thenAnswer((_) async => 0.0);

      final states = <PlaybackState>[];
      player.stateStream.listen(states.add);

      // Trigger play() which calls _listenToState().
      await player.play(
        albumId: 'test-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test Track'),
      );

      // Simulate MusicKit reporting playing.
      stateController.add(
        MusicPlayerState(
          playbackRate: 1.0,
          playbackStatus: MusicPlayerPlaybackStatus.playing,
          repeatMode: MusicPlayerRepeatMode.none,
          shuffleMode: MusicPlayerShuffleMode.off,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final playingStates = states.where((s) => s.isPlaying).toList();
      expect(playingStates, isNotEmpty);

      // Simulate pause.
      stateController.add(
        MusicPlayerState(
          playbackRate: 1.0,
          playbackStatus: MusicPlayerPlaybackStatus.paused,
          repeatMode: MusicPlayerRepeatMode.none,
          shuffleMode: MusicPlayerShuffleMode.off,
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states.last.isPlaying, false);

      await stateController.close();
      await queueController.close();
    });

    test('pause delegates to MusicKit', () async {
      when(() => mockMusicKit.pause()).thenAnswer((_) async {});
      await player.pause();
      verify(() => mockMusicKit.pause()).called(1);
    });

    test('resume delegates to MusicKit play', () async {
      when(() => mockMusicKit.play()).thenAnswer((_) async {});
      await player.resume();
      verify(() => mockMusicKit.play()).called(1);
    });

    test('stop delegates to MusicKit', () async {
      when(() => mockMusicKit.stop()).thenAnswer((_) async {});
      await player.stop();
      verify(() => mockMusicKit.stop()).called(1);
    });

    test('nextTrack delegates to skipToNextEntry', () async {
      when(() => mockMusicKit.skipToNextEntry()).thenAnswer((_) async {});
      await player.nextTrack();
      verify(() => mockMusicKit.skipToNextEntry()).called(1);
    });

    test('prevTrack delegates to skipToPreviousEntry', () async {
      when(() => mockMusicKit.skipToPreviousEntry()).thenAnswer((_) async {});
      await player.prevTrack();
      verify(() => mockMusicKit.skipToPreviousEntry()).called(1);
    });
  });
}
