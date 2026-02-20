import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'debug_settings.g.dart';

const _tag = 'DebugSettings';

const _keyReplay = 'debug.replay_enabled';
const _keyMaskText = 'debug.mask_all_text';
const _keyMaskImages = 'debug.mask_all_images';
const _keyNfcEnabled = 'debug.nfc_enabled';

/// User-controlled Sentry diagnostics preferences.
///
/// Stored in SharedPreferences and read by main() before SentryFlutter.init,
/// so changes take effect on the next app launch.
class DebugSettings {
  const DebugSettings({
    required this.replayEnabled,
    required this.maskAllText,
    required this.maskAllImages,
    required this.nfcEnabled,
  });

  /// Load from SharedPreferences. Defaults:
  /// - replayEnabled: true in debug builds, false in release
  /// - maskAllText: true (privacy-first)
  /// - maskAllImages: true (privacy-first)
  /// - nfcEnabled: false (experimental)
  factory DebugSettings.fromPrefs(SharedPreferences prefs) => DebugSettings(
    replayEnabled: prefs.getBool(_keyReplay) ?? kDebugMode,
    maskAllText: prefs.getBool(_keyMaskText) ?? true,
    maskAllImages: prefs.getBool(_keyMaskImages) ?? true,
    nfcEnabled: prefs.getBool(_keyNfcEnabled) ?? false,
  );

  /// Whether session replay is captured at all.
  /// Default: true in debug builds, false in release.
  final bool replayEnabled;

  /// Whether all text widgets are replaced with blocks in replay frames.
  final bool maskAllText;

  /// Whether network/asset images are replaced with blocks in replay frames.
  final bool maskAllImages;

  /// Whether NFC tag reading/writing is enabled. Experimental.
  final bool nfcEnabled;

  DebugSettings copyWith({
    bool? replayEnabled,
    bool? maskAllText,
    bool? maskAllImages,
    bool? nfcEnabled,
  }) => DebugSettings(
    replayEnabled: replayEnabled ?? this.replayEnabled,
    maskAllText: maskAllText ?? this.maskAllText,
    maskAllImages: maskAllImages ?? this.maskAllImages,
    nfcEnabled: nfcEnabled ?? this.nfcEnabled,
  );

  Future<void> saveTo(SharedPreferences prefs) async {
    await prefs.setBool(_keyReplay, replayEnabled);
    await prefs.setBool(_keyMaskText, maskAllText);
    await prefs.setBool(_keyMaskImages, maskAllImages);
    await prefs.setBool(_keyNfcEnabled, nfcEnabled);
  }
}

/// Riverpod notifier for the settings UI. Persists changes immediately;
/// changes take effect after the next app launch (Sentry is init-time only).
@Riverpod(keepAlive: true)
class DebugSettingsNotifier extends _$DebugSettingsNotifier {
  @override
  Future<DebugSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return DebugSettings.fromPrefs(prefs);
  }

  /// Persist [updated] and update the in-memory state.
  Future<void> save(DebugSettings updated) async {
    final prefs = await SharedPreferences.getInstance();
    await updated.saveTo(prefs);
    state = AsyncData(updated);
    Log.info(
      _tag,
      'Settings saved',
      data: {
        'replay': updated.replayEnabled,
        'maskText': updated.maskAllText,
        'maskImages': updated.maskAllImages,
      },
    );
  }
}
