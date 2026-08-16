import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_edit/screen.dart';

/// Widget tests for the parent-side tile (group) edit screen.
///
/// The tile name is required, so the "Speichern" button validates it. But
/// the cover picker auto-saves independently, and a cover change must not
/// be swallowed by the name validation just because the title field is
/// momentarily empty.
void main() {
  late AppDatabase db;
  late TileRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = TileRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildScreen(ProviderContainer container, String tileId) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
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
}
