import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The store builds remove the Sentry SDK with `tool/strip_sentry.sh`,
/// which deletes `sentry_telemetry.dart`. Any other file that imports
/// Sentry would break those builds, so this keeps Sentry in one file.
void main() {
  test('only sentry_telemetry.dart imports Sentry', () {
    final importers = [
      for (final file in Directory('lib').listSync(recursive: true))
        if (file is File &&
            file.path.endsWith('.dart') &&
            !file.path.endsWith('.g.dart') &&
            file.readAsStringSync().contains("import 'package:sentry"))
          file.path,
    ]..sort();

    expect(importers, ['lib/core/telemetry/sentry_telemetry.dart']);
  });
}
