import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_item_edit/screen.dart';

/// Widget tests for the parent-side single-item edit screen.
///
/// The screen mirrors the tile-edit screen's shape (title + cover +
/// action area) but operates on a [TileItem]. These tests cover the
/// load path (title/cover seeded from the row), the save path
/// (writes go through TileItemRepository.updateMeta), and the
/// "not found" path (deleted item).
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

  Widget buildScreen(ProviderContainer container, String itemId) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: TileItemEditScreen(itemId: itemId),
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

  testWidgets('seeds title from customTitle (overrides original title)', (
    tester,
  ) async {
    final itemId = await repo.insert(
      title: 'Original Spotify Name',
      providerUri: 'spotify:album:seed',
      cardType: 'album',
    );
    await repo.updateMeta(id: itemId, customTitle: 'Mein Titel');

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, itemId));
    // Stream propagation: provider warmup + postFrameCallback that
    // populates the TextEditingController.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final field = tester.widget<TextField>(
      find.byKey(const Key('tile_item_title_field')),
    );
    expect(
      field.controller!.text,
      'Mein Titel',
      reason:
          'customTitle takes priority — the parent already named this '
          'item, so the field should not regress to the original title',
    );
  });

  testWidgets('falls back to original title when customTitle is null', (
    tester,
  ) async {
    final itemId = await repo.insert(
      title: 'Solo Album',
      providerUri: 'spotify:album:solo',
      cardType: 'album',
    );

    // Context: customTitle stays null on a fresh insert.
    final inserted = await repo.getById(itemId);
    expect(
      inserted!.customTitle,
      isNull,
      reason: 'setup: fresh insert has no custom override',
    );

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, itemId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final field = tester.widget<TextField>(
      find.byKey(const Key('tile_item_title_field')),
    );
    expect(field.controller!.text, 'Solo Album');
  });

  testWidgets('save writes customTitle through updateMeta', (tester) async {
    final itemId = await repo.insert(
      title: 'Pre-Save Title',
      providerUri: 'spotify:album:save',
      cardType: 'album',
    );

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, itemId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Edit the title.
    await tester.enterText(
      find.byKey(const Key('tile_item_title_field')),
      'New Custom Name',
    );
    await tester.pump();

    // Save button only appears once the field is dirty.
    expect(find.byKey(const Key('save_tile_item')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save_tile_item')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final after = await repo.getById(itemId);
    expect(after!.customTitle, 'New Custom Name');
    expect(
      after.title,
      'Pre-Save Title',
      reason: 'original title is not overwritten — only customTitle changes',
    );
  });

  testWidgets('"not found" path when the item row is missing', (tester) async {
    final container = makeContainer();

    await tester.pumpWidget(buildScreen(container, 'no-such-id'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Folge nicht gefunden'), findsOneWidget);
    // No save button when there's nothing to edit.
    expect(find.byKey(const Key('save_tile_item')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"In Kachel verschieben…" tile opens the group picker', (
    tester,
  ) async {
    final itemId = await repo.insert(
      title: 'Stray Album',
      providerUri: 'spotify:album:stray',
      cardType: 'album',
    );

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, itemId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Open the picker sheet.
    await tester.tap(find.byKey(const Key('assign_to_tile')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Kachel zuweisen'), findsOneWidget);
  });

  testWidgets('a cover-only save does not create a title override', (
    tester,
  ) async {
    final itemId = await repo.insert(
      title: 'Upstream Title',
      providerUri: 'spotify:album:coveronly',
      cardType: 'album',
    );
    await repo.updateMeta(id: itemId, coverUrl: 'https://img/cover.jpg');

    final before = await repo.getById(itemId);
    expect(
      before!.customTitle,
      isNull,
      reason: 'setup: no override, the field shows the upstream title',
    );

    final container = makeContainer();
    await tester.pumpWidget(buildScreen(container, itemId));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Change only the cover (clear it) — this auto-saves without the user
    // ever touching the title field.
    expect(find.text('Entfernen'), findsOneWidget);
    await tester.tap(find.text('Entfernen'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final after = await repo.getById(itemId);
    expect(after!.coverUrl, isNull, reason: 'the cover clear persisted');
    expect(
      after.customTitle,
      isNull,
      reason:
          'a save that only changed the cover must not promote the original '
          'title into a stored override that would mask upstream changes',
    );
  });

  group('resolveCustomTitle', () {
    const original = 'Original Name';
    for (final (fieldText, expected) in <(String, String?)>[
      ('', null), // cleared -> restore original
      ('   ', null), // whitespace only -> restore original
      ('Original Name', null), // echoes original -> no override needed
      ('  Original Name  ', null), // trims to the original -> no override
      ('Mein Titel', 'Mein Titel'), // genuine override
      ('  Mein Titel  ', 'Mein Titel'), // trimmed override
    ]) {
      test('"$fieldText" over "$original" resolves to $expected', () {
        expect(resolveCustomTitle(fieldText, original), expected);
      });
    }
  });
}
