import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/player/player_error.dart';

import '../../helpers/fake_player_notifier.dart';
import '../../helpers/player_error_harness.dart';

/// Each PlayerError maps to a visual category (headline, subtitle,
/// action label) plus a technical message for parents. The error host
/// owns rendering; these tests pin the mapping per error type.
void main() {
  group('player error dialog categories', () {
    ({PlayerError error, ErrorCategory category}) caseOf(
      PlayerError error,
      ErrorCategory category,
    ) => (error: error, category: category);

    final cases = [
      caseOf(PlayerError.contentUnavailable, ErrorCategory.gone),
      caseOf(PlayerError.spotifyConnectionLost, ErrorCategory.oops),
      caseOf(PlayerError.spotifyAuthExpired, ErrorCategory.parentAction),
      caseOf(PlayerError.appleMusicAuthExpired, ErrorCategory.parentAction),
    ];

    for (final c in cases) {
      testWidgets('${c.error.name} renders the ${c.category.name} category', (
        tester,
      ) async {
        final notifier = FakePlayerNotifier(playingState);
        final container = errorHostContainer(notifier);
        addTearDown(container.dispose);

        await pumpErrorHostApp(tester, container);
        await raisePlayerError(tester, notifier, c.error);

        expect(find.text(c.category.headline), findsOneWidget);
        expect(
          find.textContaining(c.category.subtitle),
          findsOneWidget,
        );
        expect(find.text(c.category.actionLabel), findsOneWidget);
        // Technical message for parents (small print).
        expect(find.text(c.error.message), findsOneWidget);
      });
    }

    testWidgets('no dialog when there is no error', (tester) async {
      final notifier = FakePlayerNotifier(playingState);
      final container = errorHostContainer(notifier);
      addTearDown(container.dispose);

      await pumpErrorHostApp(tester, container);

      expect(find.byType(Dialog), findsNothing);
      for (final category in ErrorCategory.values) {
        expect(find.text(category.headline), findsNothing);
      }
    });
  });
}
