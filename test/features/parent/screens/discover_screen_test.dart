import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/ard/ard_providers.dart';
import 'package:lauschi/core/ard/featured_shows.dart';
import 'package:lauschi/core/database/tile_item_repository.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/discover_screen.dart';
import 'package:lauschi/features/parent/widgets/featured_section.dart';

/// Layout of "Inhalte entdecken" across screen shapes. A phone held
/// sideways used to show nothing but the hero image (#315).
void main() {
  const portrait = Size(411, 900);
  const landscape = Size(900, 411);

  Future<void> pumpDiscover(
    WidgetTester tester,
    Size size, {
    double navigationBarRight = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = FakeViewPadding(right: navigationBarRight);
    tester.view.viewPadding = FakeViewPadding(right: navigationBarRight);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    final shows = [
      for (var i = 0; i < 12; i++)
        ArdProgramSet(id: '$i', title: 'Sendung $i', numberOfElements: 3),
    ];
    final featured = [
      FeaturedItem(
        title: 'Eine Geschichte',
        showTitle: 'Die Maus',
        showId: '0',
        parts: [
          ArdItem(
            id: 'p1',
            title: 'Eine Geschichte',
            publishDate: DateTime(2026),
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ardKidsShowsProvider.overrideWith((ref) => Future.value(shows)),
          featuredItemsProvider.overrideWith((ref) => Future.value(featured)),
          existingItemUrisProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const DiscoverScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  double topOf(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('in landscape the hero leaves room for the shows', (
    tester,
  ) async {
    await pumpDiscover(tester, landscape);

    final hero = tester.getSize(find.byType(FeaturedHeroCard));
    expect(hero.height, lessThanOrEqualTo(landscape.height * 0.4));
    expect(topOf(tester, 'ALLE SENDUNGEN'), lessThan(landscape.height));
  });

  testWidgets('in portrait the hero keeps its 16:9 shape', (tester) async {
    await pumpDiscover(tester, portrait);

    final hero = tester.getSize(find.byType(FeaturedHeroCard));
    final imageWidth = portrait.width - 2 * AppSpacing.screenH;
    expect(hero.height, moreOrLessEquals(imageWidth * 9 / 16));
  });

  testWidgets('a phone in portrait shows three shows per row', (tester) async {
    await pumpDiscover(tester, portrait);

    expect(topOf(tester, 'Sendung 2'), topOf(tester, 'Sendung 0'));
    expect(topOf(tester, 'Sendung 3'), greaterThan(topOf(tester, 'Sendung 0')));
  });

  testWidgets('a wide screen fits more shows per row', (tester) async {
    await pumpDiscover(tester, landscape);

    expect(topOf(tester, 'Sendung 4'), topOf(tester, 'Sendung 0'));
  });

  testWidgets('scrolling leaves the show cards as they are', (tester) async {
    await pumpDiscover(tester, portrait);
    final before = tester.widget(find.text('Sendung 0'));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
    await tester.pump();

    expect(
      identical(tester.widget(find.text('Sendung 0')), before),
      isTrue,
      reason: 'a card built again on a scroll frame',
    );
  });

  testWidgets('shows stay clear of a navigation bar at the side', (
    tester,
  ) async {
    // Held sideways, Android puts the navigation buttons at the right edge.
    const navigationBar = 48.0;
    await pumpDiscover(tester, landscape, navigationBarRight: navigationBar);

    final labels = find.textContaining('Sendung ');
    expect(labels, findsWidgets);
    final rightmost = [
      for (var i = 0; i < labels.evaluate().length; i++)
        tester.getTopRight(labels.at(i)).dx,
    ].reduce((a, b) => a > b ? a : b);
    expect(rightmost, lessThanOrEqualTo(landscape.width - navigationBar));
  });
}
