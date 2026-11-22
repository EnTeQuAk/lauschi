/// ARD Playback: an episode whose audio file is gone.
///
/// ARD Sounds keeps listing some episodes long after their files were
/// deleted (every Betthupferl episode from 2022), and just_audio reports
/// the 404 as a generic source error. The player asks the file's server
/// instead of retrying, and the card greys out.
library;

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/features/player/player_error.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest('an episode whose file is gone fails at once and greys out', (
    $,
  ) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);

    // Answers every request the way BR's CDN answers for a deleted file.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final methods = <String>[];
    server.listen((request) async {
      methods.add(request.method);
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write('{"messages":"Episode does not exist","status":"error"}');
      await request.response.close();
    });

    final itemId = await insertTestEpisode(
      $,
      TestArdEpisode(
        showId: '7244594',
        showTitle: 'Betthupferl',
        episodeTitle: 'Benny baut (2/5): Freund',
        audioUrl: 'http://127.0.0.1:${server.port}/benny-baut-2-5-freund.mp3',
        durationSeconds: 262,
        providerUri: 'ard:item:10325987',
      ),
    );

    final container = getContainer($);
    unawaited(container.read(playerProvider.notifier).playCard(itemId));

    await waitForCondition(
      $,
      () async => container.read(playerProvider).error != null,
      description: 'an error for the missing file',
    );
    final state = container.read(playerProvider);
    expect(state.error, PlayerError.contentUnavailable);
    expect(state.isPlaying, isFalse);

    // ExoPlayer retries a failed load a few times itself before it reports
    // the error. After that the app asked the server once whether the file
    // exists, and retried nothing: a retry would add requests after it
    // within the next seconds.
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(methods.where((m) => m == 'HEAD'), hasLength(1));
    expect(methods.last, 'HEAD', reason: 'requests: $methods');

    final item = await container
        .read(tileItemRepositoryProvider)
        .getById(itemId);
    expect(item?.markedUnavailable, isNotNull);

    await stopPlayback($);
  });
}
