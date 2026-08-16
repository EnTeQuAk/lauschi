import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/ui/undo_snackbar.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/episode_tile.dart';
import 'package:mocktail/mocktail.dart';

/// A repository whose delete fails, to exercise the error path (a real
/// Drift delete won't throw on demand).
class _MockTileItemRepository extends Mock implements TileItemRepository {}

/// Tests for [EpisodeTile]'s delete / remove actions, which delete
/// immediately and offer an undo instead of a confirmation dialog.
void main() {
  late AppDatabase db;
  late TileItemRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TileItemRepository(db);
  });

  tearDown(() async {
    rootScaffoldMessengerKey.currentState?.clearSnackBars();
    await db.close();
  });

  Future<TileItem> seedGroupedCard() async {
    await db
        .into(db.groups)
        .insert(GroupsCompanion.insert(id: 'tile-1', title: 'Tile'));
    final id = await repo.insert(
      title: 'Folge 1',
      providerUri: 'ard:episode:1',
      cardType: 'episode',
    );
    await repo.assignToTile(itemId: id, tileId: 'tile-1', episodeNumber: 1);
    return (await repo.getById(id))!;
  }

  Widget host(TileItem card, {TileItemRepository? failingRepo}) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWith((_) => db),
        if (failingRepo != null)
          tileItemRepositoryProvider.overrideWith((_) => failingRepo),
      ],
      child: MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: buildAppTheme(),
        home: Scaffold(
          body: EpisodeTile(card: card, index: 0, tileId: card.groupId!),
        ),
      ),
    );
  }

  Future<void> openMenuAndTap(WidgetTester tester, String item) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('deleting a card offers undo, and undo restores it', (
    tester,
  ) async {
    final card = await seedGroupedCard();
    await tester.pumpWidget(host(card));
    await tester.pump();

    await openMenuAndTap(tester, 'Eintrag löschen');

    expect(
      await repo.getById(card.id),
      isNull,
      reason: 'the card is deleted immediately, no confirmation dialog',
    );
    expect(find.text('Eintrag gelöscht'), findsOneWidget);
    expect(find.text('Rückgängig'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final restored = await repo.getById(card.id);
    expect(restored, isNotNull, reason: 'undo restored the card');
    expect(restored!.groupId, 'tile-1');
    expect(restored.episodeNumber, 1);
  });

  testWidgets('removing a card offers undo, and undo re-groups it', (
    tester,
  ) async {
    final card = await seedGroupedCard();
    await tester.pumpWidget(host(card));
    await tester.pump();

    await openMenuAndTap(tester, 'Aus Kachel entfernen');

    expect(
      (await repo.getById(card.id))?.groupId,
      isNull,
      reason: 'the card is ungrouped immediately',
    );
    expect(find.text('Aus Kachel entfernt'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      (await repo.getById(card.id))?.groupId,
      'tile-1',
      reason: 'undo re-grouped the card',
    );
  });

  testWidgets('a failed delete shows an error, not an undo', (tester) async {
    final card = await seedGroupedCard();
    final failing = _MockTileItemRepository();
    when(() => failing.delete(any())).thenThrow(Exception('boom'));

    await tester.pumpWidget(host(card, failingRepo: failing));
    await tester.pump();

    await openMenuAndTap(tester, 'Eintrag löschen');

    expect(find.text('Löschen fehlgeschlagen'), findsOneWidget);
    expect(find.text('Rückgängig'), findsNothing);

    rootScaffoldMessengerKey.currentState?.clearSnackBars();
    await tester.pump();
  });
}
