/// Integration test for the "add ARD content" flow.
///
/// Tests the full pipeline: discover a show via ARD API, import an
/// episode via ContentImporter, verify the tile appears on the kid
/// home screen and the episode is playable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_type.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';
import 'package:patrol/patrol.dart';

import 'ard_helpers.dart';
import 'helpers.dart';

void main() {
  patrolTest(
    'add ARD content: import episode → tile appears on kid home → playable',
    ($) async {
      await pumpApp($, prefs: {'onboarding_complete': true});
      await clearAppState($);
      await pumpFrames($);

      final container = getContainer($);

      // Before: no tiles, no items.
      final tilesBefore = await container.read(tileRepositoryProvider).getAll();
      expect(tilesBefore, isEmpty, reason: 'Start with no tiles');

      // Discover a real ARD episode.
      final episode = await getStableTestEpisode(container);

      // Import it via ContentImporter (same path as the UI "add" button).
      final importer = container.read(contentImporterProvider.notifier);
      await importer.importToGroup(
        groupTitle: episode.showTitle,
        // groupCoverUrl defaults to null
        cards: [
          PendingCard(
            title: episode.episodeTitle,
            cardType: 'episode',
            provider: ProviderType.ardAudiothek,
            providerUri: episode.providerUri,
            audioUrl: episode.audioUrl,
            durationMs: episode.durationSeconds * 1000,
          ),
        ],
      );
      await pumpFrames($, count: 15);

      // After import: one tile with one item.
      final tilesAfter = await container.read(tileRepositoryProvider).getAll();
      expect(tilesAfter, hasLength(1), reason: 'Import should create one tile');
      expect(tilesAfter.first.title, episode.showTitle);

      final tileId = tilesAfter.first.id;
      final itemRepo = container.read(tileItemRepositoryProvider);
      final item = await itemRepo.getByProviderUri(episode.providerUri);
      expect(item, isNotNull, reason: 'Imported episode should exist in DB');
      expect(item!.title, episode.episodeTitle);
      expect(item.provider, ProviderType.ardAudiothek.value);
      expect(item.groupId, tileId, reason: 'Episode should be in the tile');

      // Kid home screen should show the tile.
      await pumpFrames($, count: 15);
      expect(find.byType(TileCard), findsOneWidget);

      // Tap the tile to open it.
      await $.tap(find.byType(TileCard));
      await pumpFrames($, count: 20);

      // The detail screen shows episode items. In kid mode these
      // are image tiles. Verify at least one is visible, then tap it.
      final episodeItems = find.byKey(ValueKey(item.id));
      expect(
        episodeItems,
        findsOneWidget,
        reason: 'The imported episode should appear in tile detail',
      );

      // Tap the episode to play.
      await $.tap(episodeItems);
      await pumpFrames($);

      // Player should start.
      final playerState = container.read(playerProvider);
      expect(
        playerState.activeCardId,
        isNotNull,
        reason: 'Playing should set activeCardId',
      );
    },
  );
}
