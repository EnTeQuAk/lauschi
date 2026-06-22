import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/features/tiles/screens/tile_detail/screen.dart';

db.TileItem _episode({
  required String id,
  bool isHeard = false,
  int lastPositionMs = 0,
  int sortOrder = 0,
  DateTime? markedUnavailable,
}) {
  return db.TileItem(
    id: id,
    title: 'Episode $id',
    cardType: 'album',
    provider: 'ard',
    providerUri: 'ard:$id',
    isHeard: isHeard,
    sortOrder: sortOrder,
    createdAt: DateTime(2026),
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

  test('returns first unheard when nothing in progress', () {
    final result = readNextUnheard([
      _episode(id: 'ep-1', isHeard: true),
      _episode(id: 'ep-2', sortOrder: 1),
      _episode(id: 'ep-3', sortOrder: 2),
    ]);
    expect(result?.id, 'ep-2');
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
}
