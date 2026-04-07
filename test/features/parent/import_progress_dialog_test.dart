import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/parent/widgets/import_progress_dialog.dart';

/// Regression test for LAUSCHI-1J: back-button dismissed the import
/// progress dialog mid-import, leaving the DB partially populated and
/// the parent unable to retry from a clean state. The fix wraps the
/// dialog body in `PopScope(canPop: false)` so the system back gesture
/// is consumed without popping the dialog. This file's only test
/// verifies that contract by simulating a `popRoute` platform message
/// and checking the dialog is still mounted afterward.
void main() {
  testWidgets('dialog blocks back navigation during import (LAUSCHI-1J)', (
    tester,
  ) async {
    final status = ValueNotifier<String>('Importing...');
    final progress = ValueNotifier<(int, int)>((0, 10));
    addTearDown(status.dispose);
    addTearDown(progress.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed:
                        () => showDialog<void>(
                          context: context,
                          barrierDismissible: false,
                          builder:
                              (_) => ImportProgressDialog(
                                status: status,
                                progress: progress,
                              ),
                        ),
                    child: const Text('Import'),
                  ),
                ),
              ),
        ),
      ),
    );

    // Open the dialog.
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportProgressDialog), findsOneWidget);

    // Simulate system back button via the platform channel.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        const MethodCall('popRoute'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(ImportProgressDialog),
      findsOneWidget,
      reason: 'Dialog must survive back navigation during import',
    );
  });
}
