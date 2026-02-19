import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'onboarding_provider.g.dart';

const _key = 'onboarding_complete';

/// Tracks whether onboarding has been completed.
///
/// `null` = still loading from SharedPreferences (show splash).
/// `false` = needs onboarding.
/// `true` = onboarding done.
@Riverpod(keepAlive: true)
class OnboardingComplete extends _$OnboardingComplete {
  @override
  bool? build() {
    // null = loading. Router shows splash until checkAsync resolves.
    return null;
  }

  /// Check SharedPreferences for the onboarding flag.
  Future<void> checkAsync() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  /// Mark onboarding as complete.
  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    state = true;
  }
}
