import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'onboarding_provider.g.dart';

const _tag = 'OnboardingComplete';
const _key = 'onboarding_complete';

/// Tracks whether onboarding has been completed.
///
/// Reads from SharedPreferences on first access. The router
/// redirects to /onboarding if this is false.
@Riverpod(keepAlive: true)
class OnboardingComplete extends _$OnboardingComplete {
  @override
  bool build() {
    // Start as true (don't redirect) until async check completes.
    return true;
  }

  /// Check SharedPreferences for the onboarding flag.
  Future<void> checkAsync() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool(_key) ?? false;
    Log.info(_tag, 'Checked onboarding state', data: {'complete': '$done'});
    state = done;
  }

  /// Mark onboarding as complete.
  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
    Log.info(_tag, 'Onboarding marked complete');
    state = true;
  }
}
