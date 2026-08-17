import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'app_version.g.dart';

/// App version string from the platform manifest (pubspec → APK/IPA).
///
/// Returns e.g. "2026.3.20" in release builds, or "0.0.0" if package info
/// can't be read (rather than leaving this keepAlive provider stuck in a
/// permanent error state, which would show "…" in settings forever).
@Riverpod(keepAlive: true)
Future<String> appVersion(Ref ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  } on Exception {
    return '0.0.0';
  }
}
