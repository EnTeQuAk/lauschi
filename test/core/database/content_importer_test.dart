import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/core/database/content_importer.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/database/tile_repository.dart';

/// Unit tests for [ContentImporter]'s Spotify batch import path.
///
/// Scope: `importToGroup()` with the progress callback (this is where
/// LAUSCHI-1J's "progress jumps to 100% on first item" bug lived).
/// The ARD-specific `importArdShow()` path with pagination, the
/// `_assignExistingToGroup` duplicate handler, and the 100-page safety
/// limit are NOT covered here yet — see the round-1 review for
/// context. Those deserve their own test file.
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
    final tiles = container.read(tileRepositoryProvider);
    final items = container.read(tileItemRepositoryProvider);

    // Context: empty DB before import. If there were leftover rows
    // from a previous test, the post-import count assertions below
    // would be wrong by that amount.
    expect(
      await tiles.getAll(),
      isEmpty,
      reason: 'setup: fresh DB has no tiles',
    );
    expect(
      await items.getAll(),
      isEmpty,
      reason: 'setup: fresh DB has no items',
    );

    final cards = List.generate(
      10,
      (i) => PendingCard(
        title: 'Episode ${i + 1}',
        providerUri: 'spotify:album:ep${i + 1}',
        cardType: 'album',
      ),
    );
    // Context: the generator produced 10 distinct URIs. If the
    // generator itself was broken (e.g. every card had the same
    // URI), insertIfAbsent would dedupe and the result.added would
    // be 1, not 10, and the progress callback assertion would
    // still pass for 1 item — that'd be a false pass.
    expect(cards, hasLength(10));
    expect(
      cards.map((c) => c.providerUri).toSet(),
      hasLength(10),
      reason: 'setup: every generated card has a unique URI',
    );

    final progressCalls = <(int, int)>[];

    final result = await importer.importToGroup(
      groupTitle: 'Test Series',
      cards: cards,
      onProgress: (done, total) => progressCalls.add((done, total)),
    );

    // Result contract: every card landed.
    expect(result.added, 10);

    // Context for the callback assertion: the rows actually made it
    // into the DB. If the importer was broken and result.added lied,
    // or if inserts silently failed, the progress-callback test
    // would still pass for the wrong reason. This is the gap kimi
    // and sonnet both called out.
    expect(
      await tiles.getAll(),
      hasLength(1),
      reason: 'exactly one group should be created',
    );
    expect(
      await items.getAll(),
      hasLength(10),
      reason: 'all 10 cards should be inserted',
    );

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
    final tiles = container.read(tileRepositoryProvider);
    final items = container.read(tileItemRepositoryProvider);

    // Simulate a real-world scenario: 50 episodes (like a PAW Patrol import).
    final cards = List.generate(
      50,
      (i) => PendingCard(
        title: 'Folge ${i + 1}',
        providerUri: 'spotify:album:batch-${i + 1}',
        cardType: 'album',
      ),
    );
    expect(cards, hasLength(50));
    expect(
      cards.map((c) => c.providerUri).toSet(),
      hasLength(50),
      reason: 'setup: every card has a unique URI',
    );

    final progressCalls = <(int, int)>[];

    final result = await importer.importToGroup(
      groupTitle: 'PAW Patrol',
      cards: cards,
      onProgress: (done, total) => progressCalls.add((done, total)),
    );

    expect(result.added, 50);

    // Round-trip: the cards actually landed in the DB, not just a
    // lying result.added + correct callbacks.
    expect(await tiles.getAll(), hasLength(1));
    expect(
      await items.getAll(),
      hasLength(50),
      reason: 'all 50 cards should be inserted',
    );

    // Progress must fire for EVERY item, not jump from 0 to 50.
    // This is the regression test for LAUSCHI-1J: a previous bug set
    // progress to (total, total) before the import started, skipping
    // all intermediate updates and making the parent-mode progress
    // dialog flash straight to 100% on the first card.
    expect(progressCalls, hasLength(50));

    // Verify monotonically increasing progress.
    for (var i = 0; i < 50; i++) {
      expect(progressCalls[i].$1, i + 1);
      expect(progressCalls[i].$2, 50);
    }
  });

  test('episodes are sorted by episodeNumber on import', () async {
    final importer = container.read(contentImporterProvider.notifier);
    final tiles = container.read(tileRepositoryProvider);

    // Import episodes out of order: 5, 3, 1, 4, 2.
    final cards = [
      const PendingCard(
        title: 'Folge 5',
        providerUri: 'spotify:album:ep5',
        cardType: 'album',
        episodeNumber: 5,
      ),
      const PendingCard(
        title: 'Folge 3',
        providerUri: 'spotify:album:ep3',
        cardType: 'album',
        episodeNumber: 3,
      ),
      const PendingCard(
        title: 'Folge 1',
        providerUri: 'spotify:album:ep1',
        cardType: 'album',
        episodeNumber: 1,
      ),
      const PendingCard(
        title: 'Folge 4',
        providerUri: 'spotify:album:ep4',
        cardType: 'album',
        episodeNumber: 4,
      ),
      const PendingCard(
        title: 'Folge 2',
        providerUri: 'spotify:album:ep2',
        cardType: 'album',
        episodeNumber: 2,
      ),
    ];

    await importer.importToGroup(
      groupTitle: 'TKKG',
      cards: cards,
    );

    final allTiles = await tiles.getAll();
    expect(allTiles, hasLength(1));

    final items = await tiles.watchItems(allTiles.first.id).first;
    final numbers = items.map((i) => i.episodeNumber).toList();
    expect(numbers, [1, 2, 3, 4, 5]);
  });

  test('episodes without episodeNumber sort after numbered ones', () async {
    final importer = container.read(contentImporterProvider.notifier);
    final tiles = container.read(tileRepositoryProvider);

    final cards = [
      const PendingCard(
        title: 'Bonus',
        providerUri: 'spotify:album:bonus',
        cardType: 'album',
      ),
      const PendingCard(
        title: 'Folge 2',
        providerUri: 'spotify:album:ep2',
        cardType: 'album',
        episodeNumber: 2,
      ),
      const PendingCard(
        title: 'Folge 1',
        providerUri: 'spotify:album:ep1',
        cardType: 'album',
        episodeNumber: 1,
      ),
    ];

    await importer.importToGroup(
      groupTitle: 'Mixed',
      cards: cards,
    );

    final allTiles = await tiles.getAll();
    final items = await tiles.watchItems(allTiles.first.id).first;
    final titles = items.map((i) => i.title).toList();
    expect(titles, ['Folge 1', 'Folge 2', 'Bonus']);
  });

  test('import without onProgress does not crash', () async {
    final importer = container.read(contentImporterProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);

    final result = await importer.importToGroup(
      groupTitle: 'No Progress',
      cards: [
        const PendingCard(
          title: 'Ep 1',
          providerUri: 'spotify:album:np1',
          cardType: 'album',
        ),
      ],
    );

    // The "does not crash" test is a low bar. Also verify the card
    // actually made it into the DB — otherwise we're just testing
    // that null-callback invocation doesn't throw, which is a much
    // weaker claim than "import works without a progress listener".
    expect(result.added, 1);
    expect(await items.getAll(), hasLength(1));
  });

  test('duplicate URIs in one batch are counted once', () async {
    final importer = container.read(contentImporterProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);

    // Two cards share a providerUri. insertIfAbsent dedupes the row, so
    // `added` must report 1, not 2 — it drives the "X hinzugefügt" line
    // the parent sees after an import.
    final result = await importer.importToGroup(
      groupTitle: 'Dupes',
      cards: const [
        PendingCard(
          title: 'A',
          providerUri: 'spotify:album:dup',
          cardType: 'album',
        ),
        PendingCard(
          title: 'B',
          providerUri: 'spotify:album:dup',
          cardType: 'album',
        ),
      ],
    );

    expect(
      await items.getAll(),
      hasLength(1),
      reason: 'insertIfAbsent inserts a single row',
    );
    expect(
      result.added,
      1,
      reason: 'added must match the rows actually inserted',
    );
  });

  test('a malformed providerUri fails the import without wedging it', () async {
    final importer = container.read(contentImporterProvider.notifier);
    final items = container.read(tileItemRepositoryProvider);

    // ProviderType.fromUri throws ArgumentError (an Error, not an
    // Exception) on an unknown prefix. If the importer only caught
    // Exception, that error would escape, state would stay ImportRunning,
    // and every later import would be blocked until the app restarts.
    await expectLater(
      importer.importToGroup(
        groupTitle: 'Broken',
        cards: const [
          PendingCard(
            title: 'Bad',
            providerUri: 'bogus:album:1',
            cardType: 'album',
          ),
        ],
      ),
      throwsArgumentError,
    );

    // The importer released itself into a terminal state.
    expect(
      importer.state.isImporting,
      isFalse,
      reason: 'a failed import must not stay stuck in ImportRunning',
    );

    // Prove it is usable again: a subsequent valid import runs to
    // completion instead of throwing StateError('Import already in
    // progress').
    final result = await importer.importToGroup(
      groupTitle: 'Good',
      cards: const [
        PendingCard(
          title: 'Fine',
          providerUri: 'spotify:album:ok1',
          cardType: 'album',
        ),
      ],
    );
    expect(result.added, 1);
    expect(await items.getAll(), hasLength(1));
  });
}
