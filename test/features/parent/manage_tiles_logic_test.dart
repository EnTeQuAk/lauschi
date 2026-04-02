import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart';
import 'package:lauschi/features/parent/screens/manage_tiles/screen.dart';

Tile _tile({
  required String id,
  String title = 'Test',
  String? coverUrl,
}) => Tile(
  id: id,
  title: title,
  coverUrl: coverUrl,
  sortOrder: 0,
  createdAt: DateTime(2026),
  contentType: 'hoerspiel',
);

void main() {
  group('folderName', () {
    test('empty list returns Leerer Ordner', () {
      expect(folderName([]), 'Leerer Ordner');
    });

    test('single child uses its title', () {
      expect(folderName([_tile(id: '1', title: 'TKKG')]), 'TKKG');
    });

    test('two children joined with &', () {
      final tiles = [
        _tile(id: '1', title: 'TKKG'),
        _tile(id: '2', title: 'Bibi'),
      ];
      expect(folderName(tiles), 'TKKG & Bibi');
    });

    test('three or more uses & mehr', () {
      final tiles = [
        _tile(id: '1', title: 'TKKG'),
        _tile(id: '2', title: 'Bibi'),
        _tile(id: '3', title: 'Maus'),
      ];
      expect(folderName(tiles), 'TKKG, Bibi & mehr');
    });
  });

  group('buildTileDisplayItem', () {
    test('leaf tile uses tile title', () {
      final tile = _tile(id: 't1', title: 'Die Maus');
      final item = buildTileDisplayItem(
        tile,
        children: const [],
        episodeCount: 5,
      );
      expect(item.title, 'Die Maus');
      expect(item.episodeCount, 5);
      expect(item.childCount, 0);
      expect(item.childCoverUrls, isEmpty);
    });

    test('folder derives name from children', () {
      final tile = _tile(id: 'f1', title: 'Ordner');
      final children = [
        _tile(id: 'c1', title: 'TKKG'),
        _tile(id: 'c2', title: 'Bibi'),
      ];
      final item = buildTileDisplayItem(
        tile,
        children: children,
        episodeCount: 0,
      );
      expect(item.title, 'TKKG & Bibi');
      expect(item.childCount, 2);
    });

    test('takes up to 4 child covers', () {
      final tile = _tile(id: 'f1');
      final children = List.generate(
        6,
        (i) => _tile(id: 'c$i', coverUrl: 'https://img/$i.jpg'),
      );
      final item = buildTileDisplayItem(
        tile,
        children: children,
        episodeCount: 0,
      );
      expect(item.childCoverUrls, hasLength(4));
    });

    test('skips children without cover URL', () {
      final tile = _tile(id: 'f1');
      final children = [
        _tile(id: 'c1', coverUrl: 'https://img/1.jpg'),
        _tile(id: 'c2'), // no cover
        _tile(id: 'c3', coverUrl: 'https://img/3.jpg'),
      ];
      final item = buildTileDisplayItem(
        tile,
        children: children,
        episodeCount: 0,
      );
      expect(item.childCoverUrls, ['https://img/1.jpg', 'https://img/3.jpg']);
    });
  });
}
