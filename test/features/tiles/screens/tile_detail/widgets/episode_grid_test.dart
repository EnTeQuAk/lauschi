import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/router/app_router.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/player/player_provider.dart';
import 'package:lauschi/features/tiles/screens/tile_detail/widgets/episode_grid.dart';

db.TileItem _episode(int n, {bool unavailable = false}) => db.TileItem(
  id: 'ep$n',
  title: 'Folge $n',
  cardType: 'album',
  provider: 'spotify',
  providerUri: 'spotify:album:ep$n',
  isHeard: false,
  createdAt: DateTime(2026),
  totalTracks: 1,
  durationMs: 0,
  lastTrackNumber: 0,
  lastPositionMs: 0,
  lastElapsedMs: 0,
  episodeNumber: n,
  markedUnavailable: unavailable ? DateTime(2026) : null,
);

final _episodes = [for (var n = 1; n <= 40; n++) _episode(n)];

const PlayerGridState _idle = (
  isPlaying: false,
  isReady: true,
  isLoading: false,
  isFinished: false,
  track: null,
  activeCardId: null,
);

const _gridSize = Size(400, 400);

/// The grid on a page of its own, so a test can push a screen on top
/// and pop it again like the player does. The Weiter id and episodes
/// live in notifiers inside the page, like the providers the real tile
/// detail watches, so they update the grid while it is covered.
class _Harness extends StatelessWidget {
  const _Harness({
    required this.navigatorKey,
    required this.weiter,
    required this.episodes,
    required this.stored,
    this.onUnavailableTap,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ValueNotifier<String?> weiter;
  final ValueNotifier<List<db.TileItem>> episodes;

  /// The Weiter id in the database, which can be ahead of [weiter] while
  /// the grid is covered (Riverpod pauses covered screens).
  final ValueNotifier<String?> stored;
  final VoidCallback? onUnavailableTap;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [routeObserver],
      theme: buildAppTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: _gridSize,
            child: ListenableBuilder(
              listenable: Listenable.merge([weiter, episodes]),
              builder:
                  (context, _) => EpisodeGrid(
                    episodes: episodes.value,
                    weiterId: weiter.value,
                    player: _idle,
                    onCardTap: (_) {},
                    onUnavailableTap: onUnavailableTap ?? () {},
                    readWeiter: () async => stored.value,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  late GlobalKey<NavigatorState> navigatorKey;
  late ValueNotifier<String?> weiter;
  late ValueNotifier<List<db.TileItem>> episodes;
  late ValueNotifier<String?> stored;

  setUp(() {
    navigatorKey = GlobalKey<NavigatorState>();
    weiter = ValueNotifier('ep25');
    episodes = ValueNotifier(_episodes);
    stored = ValueNotifier('ep25');
  });

  Future<void> pumpGrid(WidgetTester tester, {VoidCallback? onTap}) async {
    await tester.pumpWidget(
      _Harness(
        navigatorKey: navigatorKey,
        weiter: weiter,
        episodes: episodes,
        stored: stored,
        onUnavailableTap: onTap,
      ),
    );
    await tester.pump();
  }

  double offset(WidgetTester tester) =>
      tester.widget<GridView>(find.byType(GridView)).controller!.offset;

  double expectedOffset(String id) {
    final index = _episodes.indexWhere((e) => e.id == id);
    return weiterScrollOffset(
      index: index,
      columns: 2,
      width: _gridSize.width,
      viewportHeight: _gridSize.height,
    );
  }

  Future<void> coverWithPlayer(WidgetTester tester) async {
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
  }

  Future<void> comeBack(WidgetTester tester) async {
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('opens at the Weiter card', (tester) async {
    await pumpGrid(tester);

    expect(offset(tester), expectedOffset('ep25'));
    expect(find.text('▶ Weiter'), findsOneWidget);
  });

  testWidgets('a Weiter change while visible does not move the grid', (
    tester,
  ) async {
    await pumpGrid(tester);
    final before = offset(tester);

    weiter.value = 'ep3';
    await tester.pumpAndSettle();

    expect(offset(tester), before);
  });

  testWidgets('coming back after the Weiter card moved scrolls to it', (
    tester,
  ) async {
    await pumpGrid(tester);
    await coverWithPlayer(tester);

    weiter.value = 'ep35';
    stored.value = 'ep35';
    await comeBack(tester);

    expect(offset(tester), expectedOffset('ep35'));
  });

  testWidgets('coming back follows the stored Weiter, not the covered '
      "widget's stale one (10-08: scrolled to 233 with Weiter on 234)", (
    tester,
  ) async {
    await pumpGrid(tester);
    await coverWithPlayer(tester);

    // The finish moved Weiter in the database, the covered screen didn't
    // hear about it yet.
    stored.value = 'ep35';
    await comeBack(tester);

    expect(offset(tester), expectedOffset('ep35'));
  });

  testWidgets('coming back to the first card scrolls up to the top', (
    tester,
  ) async {
    await pumpGrid(tester);
    await coverWithPlayer(tester);

    weiter.value = 'ep1';
    stored.value = 'ep1';
    await comeBack(tester);

    expect(offset(tester), 0);
  });

  testWidgets('coming back with Weiter unchanged keeps the kid view', (
    tester,
  ) async {
    await pumpGrid(tester);
    tester.widget<GridView>(find.byType(GridView)).controller!.jumpTo(100);
    await tester.pump();

    await coverWithPlayer(tester);
    await comeBack(tester);

    expect(offset(tester), 100);
  });

  testWidgets('a tile without a Weiter card opens at the top', (tester) async {
    weiter.value = null;
    await pumpGrid(tester);

    expect(offset(tester), 0);
    expect(find.text('▶ Weiter'), findsNothing);
  });

  testWidgets('an unavailable card explains itself on tap', (tester) async {
    var explained = 0;
    episodes.value = [_episode(1, unavailable: true), _episode(2)];
    weiter.value = 'ep2';
    await pumpGrid(tester, onTap: () => explained++);

    await tester.tap(find.bySemanticsLabel(RegExp('nicht mehr verfügbar')));

    expect(explained, 1);
  });
}
