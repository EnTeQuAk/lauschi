import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/episode_tile.dart';
import 'package:mocktail/mocktail.dart';

/// A repository whose mutating calls fail, to exercise the episode-row
/// error paths (a real Drift delete won't throw on demand).
class _MockTileItemRepository extends Mock implements TileItemRepository {}

/// Tests for [EpisodeTile]'s delete / remove actions.
///
/// A failed delete or remove used to be fire-and-forget: the row stayed
/// put and the parent got no feedback. Both now await the write and show
/// an error snackbar, matching the single-item edit screen.
void main() {
  late AppDatabase db;
  late TileItemRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TileItemRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<TileItem> seedCard() async {
    final id = await repo.insert(
      title: 'Folge 1',
      providerUri: 'ard:episode:1',
      cardType: 'episode',
    );
    return (await repo.getById(id))!;
  }

  Widget host(TileItem card) {
    final failingRepo = _MockTileItemRepository();
    when(() => failingRepo.delete(any())).thenThrow(Exception('delete failed'));
    when(
      () => failingRepo.removeFromTile(any()),
    ).thenThrow(Exception('remove failed'));

    final container = ProviderContainer(
      overrides: [tileItemRepositoryProvider.overrideWith((_) => failingRepo)],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: EpisodeTile(card: card, index: 0, tileId: 'tile-1'),
        ),
      ),
    );
  }

  testWidgets('shows an error snackbar when a delete fails', (tester) async {
    await tester.pumpWidget(host(await seedCard()));
    await tester.pump();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eintrag löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Löschen fehlgeschlagen'), findsOneWidget);
  });

  testWidgets('shows an error snackbar when a remove-from-tile fails', (
    tester,
  ) async {
    await tester.pumpWidget(host(await seedCard()));
    await tester.pump();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Kachel entfernen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Entfernen fehlgeschlagen'), findsOneWidget);
  });
}
