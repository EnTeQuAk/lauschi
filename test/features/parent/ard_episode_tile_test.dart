import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/ard/ard_models.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/ard_show_detail/widgets/ard_episode_tile.dart';

/// Tests for [ArdEpisodeTile]'s trailing action button.
///
/// During an "Alle hinzufügen" import the row is disabled, so the remove
/// (check) button must be inert too, not just the add button, otherwise a
/// parent can delete an episode mid-import and race the importer.
void main() {
  ArdItem episode() =>
      ArdItem(id: '1', title: 'Folge 1', publishDate: DateTime(2020));

  Widget host({
    required bool enabled,
    required VoidCallback onRemove,
  }) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ArdEpisodeTile(
          item: episode(),
          alreadyAdded: true,
          isAdding: false,
          enabled: enabled,
          onAdd: () {},
          onRemove: onRemove,
        ),
      ),
    );
  }

  final removeButton = find.widgetWithIcon(IconButton, Icons.check_circle);

  testWidgets('remove is disabled while an import is running', (tester) async {
    await tester.pumpWidget(host(enabled: false, onRemove: () {}));
    await tester.pump();

    expect(
      tester.widget<IconButton>(removeButton).onPressed,
      isNull,
      reason: 'the remove button must be disabled during an import',
    );
  });

  testWidgets('remove works when no import is running', (tester) async {
    var removed = false;
    await tester.pumpWidget(
      host(enabled: true, onRemove: () => removed = true),
    );
    await tester.pump();

    await tester.tap(removeButton);
    await tester.pump();
    expect(removed, isTrue);
  });
}
