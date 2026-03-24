import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';
import 'package:lauschi/core/providers/provider_type.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        tileRepositoryProvider.overrideWithValue(TileRepository(db)),
        tileItemRepositoryProvider.overrideWithValue(TileItemRepository(db)),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('onProgress fires for every item during import', () async {
    final importer = container.read(contentImporterProvider.notifier);

    final cards = List.generate(
      10,
      (i) => PendingCard(
        title: 'Episode ${i + 1}',
        providerUri: 'spotify:album:ep${i + 1}',
        cardType: 'album',
        provider: ProviderType.spotify,
      ),
    );

    final progressCalls = <(int, int)>[];

    final result = await importer.importToGroup(
      groupTitle: 'Test Series',
      cards: cards,
      onProgress: (done, total) => progressCalls.add((done, total)),
    );

    expect(result.added, 10);

    // onProgress must fire exactly once per item.
    expect(progressCalls, hasLength(10));

    // Each call should report incremental progress.
    for (var i = 0; i < 10; i++) {
      expect(progressCalls[i].$1, i + 1, reason: 'done count at step $i');
      expect(progressCalls[i].$2, 10, reason: 'total count at step $i');
    }

    // First call is (1, 10), last is (10, 10).
    expect(progressCalls.first, (1, 10));
    expect(progressCalls.last, (10, 10));
  });

  test('onProgress fires for every item in a large batch', () async {
    final importer = container.read(contentImporterProvider.notifier);

    // Simulate a real-world scenario: 50 episodes (like a PAW Patrol import).
    final cards = List.generate(
      50,
      (i) => PendingCard(
        title: 'Folge ${i + 1}',
        providerUri: 'spotify:album:batch-${i + 1}',
        cardType: 'album',
        provider: ProviderType.spotify,
      ),
    );

    final progressCalls = <(int, int)>[];

    final result = await importer.importToGroup(
      groupTitle: 'PAW Patrol',
      cards: cards,
      onProgress: (done, total) => progressCalls.add((done, total)),
    );

    expect(result.added, 50);

    // Progress must fire for EVERY item, not jump from 0 to 50.
    // This is the regression test: a previous bug set progress to
    // (total, total) before the import started, skipping all intermediate
    // updates.
    expect(progressCalls, hasLength(50));

    // Verify monotonically increasing progress.
    for (var i = 0; i < 50; i++) {
      expect(progressCalls[i].$1, i + 1);
      expect(progressCalls[i].$2, 50);
    }
  });

  test('import without onProgress does not crash', () async {
    final importer = container.read(contentImporterProvider.notifier);

    final result = await importer.importToGroup(
      groupTitle: 'No Progress',
      cards: [
        const PendingCard(
          title: 'Ep 1',
          providerUri: 'spotify:album:np1',
          cardType: 'album',
          provider: ProviderType.spotify,
        ),
      ],
    );

    expect(result.added, 1);
  });
}
