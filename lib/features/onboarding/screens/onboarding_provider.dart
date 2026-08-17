import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/log.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'onboarding_provider.g.dart';

const _tag = 'OnboardingComplete';

/// SharedPreferences key for the onboarding-complete flag.
const onboardingCompleteKey = 'onboarding_complete';

/// The onboarding-complete flag as read once in main() before the first
/// frame, overridden there. It seeds [OnboardingComplete] so the router's
/// first redirect has the real value; without it the flag would default
/// optimistically and flash the empty kid-home screen before bouncing a new
/// user to onboarding.
final onboardingCompletePreloadProvider = Provider<bool>(
  (ref) =>
      throw UnimplementedError(
        'onboardingCompletePreloadProvider must be overridden in main()',
      ),
);

/// Tracks whether onboarding has been completed. The router redirects to
/// /onboarding when this is false.
@Riverpod(keepAlive: true)
class OnboardingComplete extends _$OnboardingComplete {
  @override
  bool build() => ref.watch(onboardingCompletePreloadProvider);

  /// Mark onboarding as complete.
  Future<void> markComplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingCompleteKey, true);
    Log.info(_tag, 'Onboarding marked complete');
    state = true;
  }

  /// Reset onboarding (e.g. on logout), so the router redirects back to the
  /// login flow.
  Future<void> markIncomplete() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(onboardingCompleteKey, false);
    Log.info(_tag, 'Onboarding marked incomplete');
    state = false;
  }
}
