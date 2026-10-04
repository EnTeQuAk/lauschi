/// The Weiter card in a long tile: where it goes when an episode starts
/// and finishes, and where the grid lands when the kid comes back from
/// the player.
///
/// The reported bug: after an episode finished and the kid went back,
/// the grid scrolled far down to a badge that pointed past every heard
/// episode instead of at the next one.
library;

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/listening_repository.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

const _episodeCount = 24;

/// A tile of [_episodeCount] episodes, all playing the same real ARD
/// audio, numbered 1 to [_episodeCount]. Returns the tile id and the item
/// ids in episode order.
Future<({String tileId, List<String> itemIds})> _insertLongTile(
  PatrolIntegrationTester $,
) async {
  final container = getContainer($);
  final episode = await getStableTestEpisode(container);
  final tileId = await container
      .read(tileRepositoryProvider)
      .insert(title: 'Weiter Test');
  final items = container.read(tileItemRepositoryProvider);
  final ids = <String>[
    for (var n = 1; n <= _episodeCount; n++)
      await items.insertArdEpisode(
        title: 'Folge $n',
        providerUri: 'ard:item:weiter-test-$n',
        audioUrl: episode.audioUrl,
        durationMs: episode.durationSeconds * 1000,
        tileId: tileId,
        episodeNumber: n,
      ),
  ];
  await pumpFrames($);
  return (tileId: tileId, itemIds: ids);
}

Future<String?> _weiterOf(PatrolIntegrationTester $, String tileId) async =>
    (await getContainer(
      $,
    ).read(tileRepositoryProvider).getById(tileId))!.weiterItemId;

/// Whether the card is laid out inside the visible screen.
bool _onScreen(PatrolIntegrationTester $, String itemId) {
  final finder = find.byKey(ValueKey(itemId));
  if (finder.evaluate().isEmpty) return false;
  final rect = $.tester.getRect(finder);
  final screen = $.tester.view.physicalSize / $.tester.view.devicePixelRatio;
  return rect.bottom > 0 && rect.top < screen.height;
}

void main() {
  patrolTest('20 seconds of play make an episode the Weiter card', ($) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);
    final tile = await _insertLongTile($);
    final container = getContainer($);

    unawaited(
      container.read(playerProvider.notifier).playCard(tile.itemIds[4]),
    );
    await waitForPlayback($);
    expect(
      await _weiterOf($, tile.tileId),
      isNull,
      reason: 'a short peek moves nothing',
    );

    await waitForCondition(
      $,
      () async => await _weiterOf($, tile.tileId) == tile.itemIds[4],
      description: 'Folge 5 becomes the Weiter card',
      timeout: const Duration(seconds: 40),
    );

    await stopPlayback($);
  });

  patrolTest('finishing an episode and going back lands on the next one', (
    $,
  ) async {
    await pumpApp($, prefs: {'onboarding_complete': true});
    await clearAppState($);
    final tile = await _insertLongTile($);
    final container = getContainer($);
    final folge12 = tile.itemIds[11];
    final folge13 = tile.itemIds[12];

    // A later episode heard before: under the old rule the badge jumped
    // past it after any finish ("Folge 125 finished, badge on 179").
    await container
        .read(listeningRepositoryProvider)
        .finishItem(tile.itemIds[_episodeCount - 3]);
    await container.read(listeningRepositoryProvider).startItem(folge12);

    container.read(appRouterProvider).go(AppRoutes.tileDetail(tile.tileId));
    await pumpFrames($, count: 20);
    expect(_onScreen($, folge12), isTrue, reason: 'opens at the Weiter card');

    await $.tester.tap(find.byKey(ValueKey(folge12)));
    await waitForPlayback($);
    await waitForDurationKnown($);
    final notifier = container.read(playerProvider.notifier);
    await notifier.seek(container.read(playerProvider).durationMs - 3000);
    await waitForCondition(
      $,
      () async => await _weiterOf($, tile.tileId) == folge13,
      description: 'Weiter moves to Folge 13 when Folge 12 ends',
      timeout: const Duration(seconds: 15),
    );

    await $.tester.tap(find.byKey(const Key('player_close_button')));
    await pumpFrames($, count: 30);

    expect(_onScreen($, folge13), isTrue, reason: 'the grid shows Folge 13');
    expect(
      _onScreen($, tile.itemIds.last),
      isFalse,
      reason: 'the grid did not jump to the bottom',
    );
    expect(find.text('▶ Weiter'), findsOneWidget);

    await stopPlayback($);
  });
}
