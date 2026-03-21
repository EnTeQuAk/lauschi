import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/apple_music_player.dart';
import 'package:lauschi/features/player/apple_music_webview_bridge.dart';
import 'package:lauschi/features/player/player_state.dart';
import 'package:mocktail/mocktail.dart';

class MockAppleMusicBridge extends Mock implements AppleMusicWebViewBridge {}

void main() {
  group('AppleMusicPlayer', () {
    late MockAppleMusicBridge mockBridge;
    late AppleMusicPlayer player;

    setUp(() {
      mockBridge = MockAppleMusicBridge();
      when(() => mockBridge.currentState).thenReturn(const PlaybackState());
      when(() => mockBridge.trackIndex).thenReturn(0);
      when(() => mockBridge.totalTracks).thenReturn(0);
      when(() => mockBridge.hasNextTrack).thenReturn(false);
      when(() => mockBridge.stateStream).thenAnswer(
        (_) => const Stream<PlaybackState>.empty(),
      );
      player = AppleMusicPlayer(mockBridge);
    });

    tearDown(() async {
      await player.dispose();
    });

    test('initial state: not playing, position 0', () {
      expect(player.currentPositionMs, 0);
      expect(player.currentTrackNumber, 1);
      expect(player.hasNextTrack, false);
    });

    test('currentTrackNumber is 1-based from bridge trackIndex', () {
      when(() => mockBridge.trackIndex).thenReturn(3);
      expect(player.currentTrackNumber, 4);
    });

    test('hasNextTrack delegates to bridge', () {
      when(() => mockBridge.hasNextTrack).thenReturn(true);
      expect(player.hasNextTrack, true);
    });

    test('pause delegates to bridge', () async {
      when(() => mockBridge.pause()).thenAnswer((_) async {});
      await player.pause();
      verify(() => mockBridge.pause()).called(1);
    });

    test('resume delegates to bridge', () async {
      when(() => mockBridge.resume()).thenAnswer((_) async {});
      await player.resume();
      verify(() => mockBridge.resume()).called(1);
    });

    test('stop delegates to bridge', () async {
      when(() => mockBridge.stop()).thenAnswer((_) async {});
      await player.stop();
      verify(() => mockBridge.stop()).called(1);
    });

    test('seek delegates to bridge', () async {
      when(() => mockBridge.seek(any())).thenAnswer((_) async {});
      await player.seek(30000);
      verify(() => mockBridge.seek(30000)).called(1);
    });

    test('nextTrack delegates to bridge', () async {
      when(() => mockBridge.nextTrack()).thenAnswer((_) async {});
      await player.nextTrack();
      verify(() => mockBridge.nextTrack()).called(1);
    });

    test('prevTrack delegates to bridge', () async {
      when(() => mockBridge.prevTrack()).thenAnswer((_) async {});
      await player.prevTrack();
      verify(() => mockBridge.prevTrack()).called(1);
    });

    test('play calls bridge playAlbum', () async {
      when(
        () => mockBridge.playAlbum(any(), trackIndex: any(named: 'trackIndex')),
      ).thenAnswer((_) async {});

      await player.play(
        albumId: 'test-album-123',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test Track'),
      );

      verify(() => mockBridge.playAlbum('test-album-123')).called(1);
    });

    test('play with positionMs seeks after delay', () async {
      when(
        () => mockBridge.playAlbum(any(), trackIndex: any(named: 'trackIndex')),
      ).thenAnswer((_) async {});
      when(() => mockBridge.seek(any())).thenAnswer((_) async {});

      await player.play(
        albumId: 'test-album',
        trackInfo: const TrackInfo(uri: 'test:uri', name: 'Test Track'),
        positionMs: 45000,
      );

      // Seek happens after a 2s delay.
      await Future<void>.delayed(const Duration(seconds: 3));
      verify(() => mockBridge.seek(45000)).called(1);
    });

    test('dispose does not dispose bridge (bridge outlives player)', () async {
      // Bridge lifecycle is managed by AppleMusicSession.
      // AppleMusicPlayer.dispose() should NOT touch the bridge.
      await player.dispose();
      verifyNever(() => mockBridge.tearDown());
    });
  });
}
