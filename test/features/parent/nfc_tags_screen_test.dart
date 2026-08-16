import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/database/app_database.dart' as db;
import 'package:lauschi/core/nfc/nfc_service.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/nfc_tags_screen.dart';
import 'package:mocktail/mocktail.dart';

class _MockNfcService extends Mock implements NfcService {}

void main() {
  group('shortTagUid', () {
    test('truncates a long UID', () {
      expect(shortTagUid('0123456789abcdef'), '01234567…');
    });

    test('returns a short UID unchanged (no RangeError)', () {
      expect(shortTagUid('ab:cd'), 'ab:cd');
    });

    test('returns an exactly-8 UID unchanged', () {
      expect(shortTagUid('01234567'), '01234567');
    });
  });

  testWidgets('deleting the last tag still shows the confirmation', (
    tester,
  ) async {
    // A hand-driven stream (not the Drift one) so the tree teardown stays
    // clean; deleteMapping pushes the now-empty list.
    final tags = StreamController<List<db.NfcTag>>();
    addTearDown(tags.close);
    final tag = db.NfcTag(
      id: 1,
      tagUid: 'abcd1234ef',
      targetType: 'group',
      targetId: 'tile-1',
      createdAt: DateTime(2020),
    );

    // deleteMapping emits the empty list immediately but only completes when
    // we release the gate. That lets the list rebuild into the empty state
    // (unmounting the row) *before* the handler resumes, which is exactly the
    // window where the row's own context would be dead.
    final gate = Completer<void>();
    final service = _MockNfcService();
    // mocktail records the invocation, so the closure can't be a tearoff.
    // ignore: unnecessary_lambdas
    when(() => service.watchAll()).thenAnswer((_) => tags.stream);
    when(() => service.deleteMapping(any())).thenAnswer((_) {
      tags.add([]);
      return gate.future;
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [nfcServiceProvider.overrideWith((ref) => service)],
        child: MaterialApp(theme: buildAppTheme(), home: const NfcTagsScreen()),
      ),
    );
    tags.add([tag]);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byKey(const Key('delete_nfc_abcd1234ef')), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_nfc_abcd1234ef')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The row has unmounted into the empty state, and the handler hasn't
    // resumed yet (still awaiting the gate), so no confirmation yet.
    expect(find.text('Noch keine NFC-Tags'), findsOneWidget);
    expect(find.text('abcd1234ef entfernt'), findsNothing);

    // Release the delete: the handler resumes with the row gone.
    gate.complete();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The confirmation still shows, via the messenger captured up front.
    expect(find.text('abcd1234ef entfernt'), findsOneWidget);

    // Dispose the tree so the snackbar timer cancels before teardown.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
