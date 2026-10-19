#!/usr/bin/env bash
# Fails when a built APK, AAB or IPA still contains the Sentry SDK.
#
# Usage: tool/check_no_sentry.sh <app.apk|app.aab|app.ipa>
set -euo pipefail

app=$1
# Native libraries (libsentry.so) and the iOS Sentry.framework show up
# by file name.
hits=$(unzip -l "$app" | grep -ic 'sentry' || true)
case "$app" in
  *.apk | *.aab)
    # The Android SDK's classes live under io.sentry in the dex files.
    dex_hits=$(unzip -p "$app" '*.dex' | grep -ac 'Lio/sentry/' || true)
    hits=$((hits + dex_hits))
    ;;
  *.ipa) ;;
  *)
    echo "Don't know how to look into $app" >&2
    exit 2
    ;;
esac

if [ "$hits" -gt 0 ]; then
  echo "$app still contains Sentry. Was tool/strip_sentry.sh run before the build?" >&2
  exit 1
fi
echo "$app contains no Sentry."
