import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// A folder's cover is made from its tiles' covers. With fewer than four
/// tiles the covers share the whole square instead of leaving empty
/// slots: a two-tile folder used to fill only its top half (#308). A tile
/// without a cover keeps its slot, so the folder still reads as a folder.
void main() {
  Future<void> pumpCovers(WidgetTester tester, List<String?> covers) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: TileCard(
                title: 'Ordner',
                episodeCount: 0,
                childCount: covers.length,
                kidMode: true,
                childCoverUrls: covers,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder emptySlots() => find.byWidgetPredicate(
    (w) => w is ColoredBox && w.color == AppColors.surfaceDim,
  );

  Future<List<Rect>> pumpFolder(WidgetTester tester, int tiles) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: TileCard(
                title: 'Ordner',
                episodeCount: 0,
                childCount: tiles,
                kidMode: true,
                childCoverUrls: [
                  for (var i = 0; i < tiles; i++)
                    'https://covers.example/$i.jpg',
                ],
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final covers = find.byType(CachedNetworkImage);
    return [
      for (var i = 0; i < covers.evaluate().length; i++)
        tester.getRect(covers.at(i)),
    ];
  }

  testWidgets('one tile fills the folder', (tester) async {
    final covers = await pumpFolder(tester, 1);

    expect(covers, hasLength(1));
    expect(covers[0].height, moreOrLessEquals(covers[0].width));
  });

  testWidgets('two tiles sit side by side at full height', (tester) async {
    final covers = await pumpFolder(tester, 2);

    expect(covers, hasLength(2));
    expect(covers[1].top, covers[0].top);
    expect(covers[1].left, greaterThan(covers[0].right));
    for (final cover in covers) {
      expect(cover.height, greaterThan(cover.width * 1.8));
    }
  });

  testWidgets('three tiles put one tall cover next to two small ones', (
    tester,
  ) async {
    final covers = await pumpFolder(tester, 3);

    expect(covers, hasLength(3));
    final [tall, top, bottom] = covers;
    expect(tall.height, greaterThan(tall.width * 1.8));
    expect(top.left, greaterThan(tall.right));
    expect(bottom.left, top.left);
    expect(bottom.top, greaterThan(top.bottom));
    expect(top.height + bottom.height, lessThan(tall.height));
  });

  testWidgets('a tile without a cover keeps an empty square', (tester) async {
    await pumpCovers(tester, ['https://covers.example/0.jpg', null]);

    final cover = tester.getRect(find.byType(CachedNetworkImage));
    expect(cover.height, greaterThan(cover.width * 1.8), reason: 'half');
    expect(emptySlots(), findsOneWidget);
  });

  testWidgets('a folder of tiles without covers still shows its squares', (
    tester,
  ) async {
    await pumpCovers(tester, [null, null, null]);

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(emptySlots(), findsNWidgets(3));
  });

  // A cover in a two-tile folder is as tall as a single tile's.
  testWidgets('covers decode as sharp as a single tile', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TileCard(
          title: 'Kachel',
          episodeCount: 1,
          coverUrl: 'https://covers.example/single.jpg',
          kidMode: true,
          onTap: () {},
        ),
      ),
    );
    final single =
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .memCacheWidth;

    await pumpFolder(tester, 2);

    expect(
      tester
          .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .map((image) => image.memCacheWidth),
      everyElement(single),
    );
  });

  testWidgets('four tiles make a 2x2 grid', (tester) async {
    final covers = await pumpFolder(tester, 4);

    expect(covers, hasLength(4));
    for (final cover in covers) {
      expect(cover.height, moreOrLessEquals(cover.width));
    }
    expect(covers[2].top, greaterThan(covers[0].bottom));
  });
}
