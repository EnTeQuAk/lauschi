import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/core/ui/undo_snackbar.dart';
import 'package:lauschi/features/parent/screens/tile_edit/screen.dart';

import '../../helpers/pushed_screen.dart';

/// Widget tests for the parent-side tile (group) edit screen.
///
/// The tile name is required, so the "Speichern" button validates it. But
/// the cover picker auto-saves independently, and a cover change must not
/// be swallowed by the name validation just because the title field is
/// momentarily empty. Destructive actions delete immediately and offer an
/// undo instead of a confirmation dialog.
void main() {
  late AppDatabase db;
  late TileRepository repo;
  late TileItemRepository itemRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TileRepository(db);
    itemRepo = TileItemRepository(db);
  });

  tearDown(() async {
    rootScaffoldMessengerKey.currentState?.clearSnackBars();
    await db.close();
  });

  Widget buildScreen(ProviderContainer container, String tileId) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: buildAppTheme(),
        home: TileEditScreen(tileId: tileId),
      ),
    );
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((_) => db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Leaving with a new name used to throw it away unless the parent had
  // tapped "Speichern" first (#307). The cover saves itself, so the name
  // does too.
  testWidgets('a renamed tile keeps its name when left with the back arrow', (
    tester,
  ) async {
    final tileId = await repo.insert(title: 'TKKG');
    await pushScreen(tester, makeContainer(), TileEditScreen(tileId: tileId));

    await tester.enterText(
      find.byKey(const Key('tile_title_field')),
      'Die Bande',
    );
    await tester.pump();
    await tester.pageBack();
    await settle(tester);

    expect((await repo.getById(tileId))!.title, 'Die Bande');
    expect(find.text('Kachel gespeichert'), findsOneWidget);
  });

  testWidgets('a renamed tile keeps its name when left with system back', (
    tester,
  ) async {
    final tileId = await repo.insert(title: 'TKKG');
    await pushScreen(tester, makeContainer(), TileEditScreen(tileId: tileId));

    await tester.enterText(
      find.byKey(const Key('tile_title_field')),
      'Die Bande',
    );
    await tester.pump();
    await tester.binding.handlePopRoute();
    await settle(tester);

    expect((await repo.getById(tileId))!.title, 'Die Bande');
  });

  testWidgets('leaving with an empty name keeps the stored one', (
    tester,
  ) async {
    final tileId = await repo.insert(title: 'TKKG');
    await pushScreen(tester, makeContainer(), TileEditScreen(tileId: tileId));

    await tester.enterText(find.byKey(const Key('tile_title_field')), '  ');
    await tester.pump();
    await tester.pageBack();
    await settle(tester);

    expect((await repo.getById(tileId))!.title, 'TKKG');
    expect(find.text('Kachel gespeichert'), findsNothing);
  });

  testWidgets('deleting a renamed tile keeps the undo', (tester) async {
    final tileId = await repo.insert(title: 'TKKG');
    await pushScreen(tester, makeContainer(), TileEditScreen(tileId: tileId));

    await tester.enterText(
      find.byKey(const Key('tile_title_field')),
      'Die Bande',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('tile_edit_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kachel löschen'));
    await settle(tester);

    expect(await repo.getById(tileId), isNull);
    expect(find.text('Kachel gelöscht'), findsOneWidget);
    expect(find.text('Kachel gespeichert'), findsNothing);
  });

  testWidgets('a cover change persists even when the title field is empty', (
    tester,
  ) async {
    final tileId = await repo.insert(
      title: 'TKKG',
      coverUrl: 'https://img/cover.jpg',
    );

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, tileId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Clear the required name field, then clear the cover. The two edits
    // are independent: the cover clear must still persist.
    await tester.enterText(find.byKey(const Key('tile_title_field')), '');
    await tester.pump();

    expect(find.text('Entfernen'), findsOneWidget);
    await tester.tap(find.text('Entfernen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final after = await repo.getById(tileId);
    expect(
      after!.coverUrl,
      isNull,
      reason: 'the cover clear persisted despite the empty title field',
    );
    expect(
      after.title,
      'TKKG',
      reason: 'the cover-only auto-save left the required title untouched',
    );
    expect(
      find.text('Bitte einen Namen eingeben'),
      findsNothing,
      reason: 'a cover change must not trigger the name-required validation',
    );
  });

  testWidgets('"Alle Folgen löschen" deletes immediately and undo restores', (
    tester,
  ) async {
    final tileId = await repo.insert(title: 'TKKG');
    final e1 = await itemRepo.insert(
      title: 'Folge 1',
      providerUri: 'ard:1',
      cardType: 'episode',
    );
    final e2 = await itemRepo.insert(
      title: 'Folge 2',
      providerUri: 'ard:2',
      cardType: 'episode',
    );
    await itemRepo.assignToTile(itemId: e1, tileId: tileId, episodeNumber: 1);
    await itemRepo.assignToTile(itemId: e2, tileId: tileId, episodeNumber: 2);

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, tileId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Open the app-bar menu (the episode rows have their own menus) and
    // delete all episodes, with no confirm dialog.
    await tester.tap(find.byKey(const Key('tile_edit_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alle Folgen löschen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(await itemRepo.getById(e1), isNull);
    expect(await itemRepo.getById(e2), isNull);
    expect(find.text('2 Einträge gelöscht'), findsOneWidget);

    await tester.tap(find.text('Rückgängig'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect((await itemRepo.getById(e1))?.groupId, tileId, reason: 'undo');
    expect((await itemRepo.getById(e2))?.groupId, tileId, reason: 'undo');
  });
}
