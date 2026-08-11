import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/tiles/widgets/tile_card.dart';

/// Stored cover URLs go stale (CDN links rotate), so every cover image
/// must carry an error fallback: without one a failed load renders a
/// blank card and reports an uncaught image exception to Sentry.
///
/// Asserted at the configuration level because CachedNetworkImage's
/// failure path needs platform channels (cache manager file IO) that
/// widget tests don't provide.
void main() {
  Iterable<CachedNetworkImage> coverImages(WidgetTester tester) =>
      tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage));

  testWidgets('the stacked-art cover has error and placeholder builders', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: TileCard(
                title: 'TKKG',
                episodeCount: 12,
                kidMode: true,
                coverUrl: 'https://covers.example/rotated-away.jpg',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final images = coverImages(tester).toList();
    expect(images, isNotEmpty, reason: 'precondition: cover renders via CNI');
    for (final image in images) {
      expect(image.errorWidget, isNotNull);
      expect(image.placeholder, isNotNull);
    }
  });

  testWidgets('every mosaic slot has error and placeholder builders', (
    tester,
  ) async {
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
                childCount: 2,
                kidMode: true,
                childCoverUrls: const [
                  'https://covers.example/gone-1.jpg',
                  'https://covers.example/gone-2.jpg',
                ],
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final images = coverImages(tester).toList();
    expect(images, hasLength(2), reason: 'precondition: two mosaic slots');
    for (final image in images) {
      expect(image.errorWidget, isNotNull);
      expect(image.placeholder, isNotNull);
    }
  });
}
