#!/usr/bin/env bash
# Removes the Sentry SDK from the app, for the store builds.
#
# The store builds collect no data. With the SDK in the binary it would
# never start, but a tracker scan such as Exodus would still list it. The
# script removes the Sentry packages, switches lib/core/telemetry/ to the
# backend that collects nothing and deletes the Sentry one. Run it on a
# fresh checkout before `flutter pub get`, it edits tracked files.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter pub remove sentry_flutter sentry_dio
perl -pi -e 's/sentry_telemetry\.dart/noop_telemetry.dart/' lib/core/telemetry/telemetry.dart
rm lib/core/telemetry/sentry_telemetry.dart

if grep -rl "package:sentry" lib; then
  echo "The files above still import Sentry. Report through lib/core/telemetry/ instead." >&2
  exit 1
fi
