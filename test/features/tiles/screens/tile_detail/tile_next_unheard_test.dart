import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/features/tiles/screens/tile_detail/screen.dart';

db.TileItem _episode({
  required String id,
  bool isHeard = false,
  int lastPositionMs = 0,
  int? sortOrder,
  int? episodeNumber,
  DateTime? markedUnavailable,
  DateTime? createdAt,
}) {
  return db.TileItem(
    id: id,
    title: 'Episode $id',
    cardType: 'album',
    provider: 'ard',
    providerUri: 'ard:$id',
    isHeard: isHeard,
    sortOrder: sortOrder,
    episodeNumber: episodeNumber,
    createdAt: createdAt ?? DateTime(2026),
    totalTracks: 1,
    durationMs: 600000,
    lastTrackNumber: 0,
    lastPositionMs: lastPositionMs,
    markedUnavailable: markedUnavailable,
  );
}

void main() {
  db.TileItem? readNextUnheard(List<db.TileItem> episodes) {
    final container = ProviderContainer(
      overrides: [
        tileItemsProvider('tile-1').overrideWithValue(
          AsyncData(episodes),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container.read(tileNextUnheardProvider('tile-1'));
  }

  test('returns in-progress episode over first unheard', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1'),
      _episode(id: 'ep-2', sortOrder: 1, lastPositionMs: 5000),
      _episode(id: 'ep-3', sortOrder: 2),
    ]);
    expect(result?.id, 'ep-2');
  });

  test('returns first unheard after last heard', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', isHeard: true),
      _episode(id: 'ep-2', sortOrder: 1),
      _episode(id: 'ep-3', sortOrder: 2),
    ]);
    expect(result?.id, 'ep-2');
  });

  test('skips earlier unheard episodes when later ones are heard', () {
    // User started at ep-3 and finished it. ep-1 and ep-2 were never played.
    // Badge should point to ep-4, not ep-1.
    final result = readNextUnheard([
      _episode(id: 'ep-1'),
      _episode(id: 'ep-2', sortOrder: 1),
      _episode(id: 'ep-3', sortOrder: 2, isHeard: true),
      _episode(id: 'ep-4', sortOrder: 3),
      _episode(id: 'ep-5', sortOrder: 4),
    ]);
    expect(result?.id, 'ep-4');
  });

  test('falls back to first unheard when no episodes are heard', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1'),
      _episode(id: 'ep-2', sortOrder: 1),
      _episode(id: 'ep-3', sortOrder: 2),
    ]);
    expect(result?.id, 'ep-1');
  });

  test('wraps to first unheard when all after last heard are heard', () {
    // User heard ep-3 and ep-4, but ep-1 and ep-2 remain unheard.
    // Nothing unheard after ep-4, so fall back to first unheard overall.
    final result = readNextUnheard([
      _episode(id: 'ep-1'),
      _episode(id: 'ep-2', sortOrder: 1),
      _episode(id: 'ep-3', sortOrder: 2, isHeard: true),
      _episode(id: 'ep-4', sortOrder: 3, isHeard: true),
    ]);
    expect(result?.id, 'ep-1');
  });

  test('returns null when all episodes are heard', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', isHeard: true),
      _episode(id: 'ep-2', sortOrder: 1, isHeard: true),
    ]);
    expect(result, isNull);
  });

  test('skips expired episodes in progress', () {
    final result = readNextUnheard([
      _episode(
        id: 'ep-1',
        lastPositionMs: 5000,
        markedUnavailable: DateTime(2026),
      ),
      _episode(id: 'ep-2', sortOrder: 1),
    ]);
    expect(result?.id, 'ep-2');
  });

  test('skips expired episodes in sequential fallback', () {
    final result = readNextUnheard([
      _episode(
        id: 'ep-1',
        markedUnavailable: DateTime(2026),
      ),
      _episode(
        id: 'ep-2',
        sortOrder: 1,
        markedUnavailable: DateTime(2026),
      ),
      _episode(id: 'ep-3', sortOrder: 2),
    ]);
    expect(result?.id, 'ep-3');
  });

  test('returns null when all unheard episodes are expired', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', isHeard: true),
      _episode(
        id: 'ep-2',
        sortOrder: 1,
        markedUnavailable: DateTime(2026),
      ),
    ]);
    expect(result, isNull);
  });

  // ── Numbered episodes + specials ────────────────────────────────────

  test('returns null for empty episode list', () {
    expect(readNextUnheard([]), isNull);
  });

  test('picks next numbered episode, not special, after heard episode', () {
    // Episodes sorted by episodeNumber, specials at end.
    // User finished ep5, badge should show ep6 (not the special).
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(id: 'ep-2', episodeNumber: 2, isHeard: true),
      _episode(id: 'ep-3', episodeNumber: 3, isHeard: true),
      _episode(id: 'ep-4', episodeNumber: 4, isHeard: true),
      _episode(id: 'ep-5', episodeNumber: 5, isHeard: true),
      _episode(id: 'ep-6', episodeNumber: 6),
      _episode(id: 'ep-7', episodeNumber: 7),
      // Explicit null: this is a special with no episode number.
      // ignore: avoid_redundant_argument_values
      _episode(id: 'special-a', episodeNumber: null),
    ]);
    expect(result?.id, 'ep-6');
  });

  test('falls through to specials when all numbered episodes are heard', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(id: 'ep-2', episodeNumber: 2, isHeard: true),
      _episode(id: 'ep-3', episodeNumber: 3, isHeard: true),
      _episode(id: 'special-a'),
      _episode(id: 'special-b'),
    ]);
    expect(result?.id, 'special-a');
  });

  test('handles gap in episode numbers', () {
    // ep6 is missing from the catalog. After hearing ep5, badge shows ep7.
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(id: 'ep-5', episodeNumber: 5, isHeard: true),
      _episode(id: 'ep-7', episodeNumber: 7),
      _episode(id: 'special-a'),
    ]);
    expect(result?.id, 'ep-7');
  });

  test('special manually sorted between numbered episodes is picked', () {
    // Parent dragged a special between ep1 and ep2 (sortOrder overrides).
    final result = readNextUnheard([
      _episode(id: 'ep-1', sortOrder: 0, episodeNumber: 1, isHeard: true),
      _episode(id: 'special-a', sortOrder: 1),
      _episode(id: 'ep-2', sortOrder: 2, episodeNumber: 2),
    ]);
    expect(result?.id, 'special-a');
  });

  test('skips heard special between numbered episodes', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', sortOrder: 0, episodeNumber: 1, isHeard: true),
      _episode(id: 'special-a', sortOrder: 1, isHeard: true),
      _episode(id: 'ep-2', sortOrder: 2, episodeNumber: 2),
    ]);
    expect(result?.id, 'ep-2');
  });

  test('wraps to first unheard when all after last heard are heard', () {
    // ep1 unheard, ep2 heard, specials heard. Wraps to ep1.
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1),
      _episode(id: 'ep-2', episodeNumber: 2, isHeard: true),
      _episode(id: 'special-a', isHeard: true),
    ]);
    expect(result?.id, 'ep-1');
  });

  test('in-progress special takes priority over next numbered episode', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(id: 'ep-2', episodeNumber: 2),
      _episode(id: 'special-a', lastPositionMs: 3000),
    ]);
    expect(result?.id, 'special-a');
  });

  test('heard episode with saved position is not considered in-progress', () {
    // Edge case: episode marked heard but still has lastPositionMs.
    final result = readNextUnheard([
      _episode(
        id: 'ep-1',
        episodeNumber: 1,
        isHeard: true,
        lastPositionMs: 5000,
      ),
      _episode(id: 'ep-2', episodeNumber: 2),
    ]);
    expect(result?.id, 'ep-2');
  });

  test('multiple specials at end, first special heard, picks second', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(id: 'special-a', isHeard: true),
      _episode(id: 'special-b'),
    ]);
    expect(result?.id, 'special-b');
  });

  test('expired numbered episode skipped, picks next available', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', episodeNumber: 1, isHeard: true),
      _episode(
        id: 'ep-2',
        episodeNumber: 2,
        markedUnavailable: DateTime(2026),
      ),
      _episode(id: 'ep-3', episodeNumber: 3),
    ]);
    expect(result?.id, 'ep-3');
  });
}
