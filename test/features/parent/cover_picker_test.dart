import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/theme/app_theme.dart';
import 'package:lauschi/features/parent/screens/tile_edit/widgets/cover_picker.dart';

/// Tests for [CoverPicker], the cover chooser shared by the tile- and
/// item-edit screens.
///
/// The parent screens create the controller empty and fill it in a
/// post-frame callback (off the build pass) with no setState. On the
/// item-edit screen there's no second provider to force a rebuild, so
/// CoverPicker must listen to its own controller or an existing cover is
/// invisible (and unremovable) until an unrelated rebuild happens.
void main() {
  Widget host(TextEditingController controller, List<String> episodeCovers) {
    return ProviderScope(
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: CoverPicker(
            controller: controller,
            episodeCovers: episodeCovers,
            onChanged: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('rebuilds when the controller is filled after mount', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, const ['https://img/cover.jpg']));
    await tester.pump();

    // Empty controller: no cover selected, so no "Entfernen" affordance.
    expect(find.text('Entfernen'), findsNothing);

    // The parent fills the controller after the first frame with no
    // setState of its own (mirrors the post-frame init the screens use).
    controller.text = 'https://img/cover.jpg';
    await tester.pump();

    expect(
      find.text('Entfernen'),
      findsOneWidget,
      reason:
          'CoverPicker must rebuild on a controller change so an existing '
          'cover becomes visible and removable without touching other fields',
    );
  });

  group('shouldApplyArtistImages', () {
    test('applies when still mounted and the ids are unchanged', () {
      expect(
        shouldApplyArtistImages(
          ranFor: ['a', 'b'],
          current: ['a', 'b'],
          mounted: true,
        ),
        isTrue,
      );
    });

    test('drops a batch whose ids changed while it was in flight', () {
      expect(
        shouldApplyArtistImages(
          ranFor: ['a'],
          current: ['b'],
          mounted: true,
        ),
        isFalse,
      );
    });

    test('drops a batch that resolved after the picker was unmounted', () {
      expect(
        shouldApplyArtistImages(
          ranFor: ['a'],
          current: ['a'],
          mounted: false,
        ),
        isFalse,
      );
    });
  });
}
