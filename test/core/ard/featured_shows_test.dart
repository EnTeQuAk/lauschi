import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/featured_shows.dart';

ArdItem _item({
  required String id,
  required String title,
  required DateTime publishDate,
  String? programSetTitle,
}) => ArdItem(
  id: id,
  title: title,
  publishDate: publishDate,
  programSetTitle: programSetTitle,
);

void main() {
  group('groupFeaturedItems', () {
    test('distinct episodes with the same title stay separate', () {
      // A daily show whose episodes all carry the same title must not
      // collapse into one fake "3 Teile" multi-part card.
      final items = [
        _item(
          id: '1',
          title: 'Gute-Nacht-Geschichte',
          publishDate: DateTime(2026, 8),
        ),
        _item(
          id: '2',
          title: 'Gute-Nacht-Geschichte',
          publishDate: DateTime(2026, 8, 2),
        ),
        _item(
          id: '3',
          title: 'Gute-Nacht-Geschichte',
          publishDate: DateTime(2026, 8, 3),
        ),
      ];

      final grouped = groupFeaturedItems(items, 'show-1');

      expect(grouped, hasLength(3));
      expect(grouped.every((g) => !g.isMultiPart), isTrue);
    });

    test('explicit (N/M) parts merge into one multi-part item', () {
      // Input shuffled to prove parts are ordered by part number.
      final items = [
        _item(
          id: '3',
          title: 'Der Schatz (3/3)',
          publishDate: DateTime(2026, 8, 3),
        ),
        _item(
          id: '1',
          title: 'Der Schatz (1/3)',
          publishDate: DateTime(2026, 8),
        ),
        _item(
          id: '2',
          title: 'Der Schatz (2/3)',
          publishDate: DateTime(2026, 8, 2),
        ),
      ];

      final grouped = groupFeaturedItems(items, 'show-1');

      expect(grouped, hasLength(1));
      final story = grouped.single;
      expect(story.isMultiPart, isTrue);
      expect(story.title, 'Der Schatz');
      expect(story.parts.map((p) => p.id), ['1', '2', '3']);
    });

    test('reports the newest part date and sorts a fresh story first', () {
      // A story whose part 1 is old but whose final part just dropped must
      // rank ahead of a standalone episode published in between.
      final story = [
        _item(id: 's1', title: 'Saga (1/2)', publishDate: DateTime(2026)),
        _item(
          id: 's2',
          title: 'Saga (2/2)',
          publishDate: DateTime(2026, 8, 10),
        ),
      ];
      final single = [
        _item(id: 'x', title: 'Einzelfolge', publishDate: DateTime(2026, 6)),
      ];

      final grouped = groupFeaturedItems([...story, ...single], 'show-1');

      final saga = grouped.firstWhere((g) => g.title == 'Saga');
      expect(
        saga.publishDate,
        DateTime(2026, 8, 10),
        reason: 'publishDate is the newest part, not the oldest',
      );
      expect(
        grouped.map((g) => g.title),
        ['Saga', 'Einzelfolge'],
        reason: 'the freshly-completed story sorts ahead of the older single',
      );
    });

    test('carries the show title as the subtitle source', () {
      final items = [
        _item(
          id: '1',
          title: 'Folge',
          publishDate: DateTime(2026, 8),
          programSetTitle: 'Die Maus',
        ),
      ];

      final grouped = groupFeaturedItems(items, 'show-1');

      expect(grouped.single.showTitle, 'Die Maus');
    });
  });
}
