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
      const children = <Tile>[];

      // Context: this is the leaf branch. The distinguishing feature
      // is an empty children list — assert it so the test doesn't
      // accidentally fall into the folder branch.
      expect(children, isEmpty, reason: 'setup: leaf tile has no children');

      final item = buildTileDisplayItem(
        tile,
        children: children,
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

      // Context: the "derives name from children" behavior only makes
      // sense if we actually have the 2 children we think we have.
      // Without this the assertion below could pass for a stale tile
      // title if the derivation logic was broken.
      expect(children, hasLength(2));
      expect(children[0].title, 'TKKG');
      expect(children[1].title, 'Bibi');

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

      // Context: the "up to 4" clamp only tests what it says if we
      // start with MORE than 4 children, all with covers. If the
      // generator silently produced null URLs or fewer rows, the
      // behavioral assertion below would be meaningless.
      expect(children, hasLength(6), reason: 'setup: 6 children > 4 cap');
      expect(
        children.every((c) => c.coverUrl != null),
        isTrue,
        reason: 'setup: every child has a cover URL',
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

      // Context: the filter only has something to filter if the
      // middle child actually lacks a cover URL. The order matters
      // too — we want to see that index 2 ends up at index 1 in the
      // output, proving the filter preserves order.
      expect(children, hasLength(3));
      expect(children[0].coverUrl, isNotNull);
      expect(children[1].coverUrl, isNull, reason: 'middle child unfiltered');
      expect(children[2].coverUrl, isNotNull);

      final item = buildTileDisplayItem(
        tile,
        children: children,
        episodeCount: 0,
      );

      expect(item.childCoverUrls, ['https://img/1.jpg', 'https://img/3.jpg']);
    });
  });
}
