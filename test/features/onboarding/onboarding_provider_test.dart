import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer withPreload({required bool done}) {
    final container = ProviderContainer(
      overrides: [onboardingCompletePreloadProvider.overrideWithValue(done)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('build reflects the preloaded value (no optimistic default)', () {
    expect(
      withPreload(done: false).read(onboardingCompleteProvider),
      isFalse,
      reason: 'a fresh user starts incomplete on the very first read',
    );
    expect(
      withPreload(done: true).read(onboardingCompleteProvider),
      isTrue,
    );
  });

  test('markIncomplete resets state and persists false', () async {
    SharedPreferences.setMockInitialValues({});
    final container = withPreload(done: true);
    expect(
      container.read(onboardingCompleteProvider),
      isTrue,
      reason: 'setup: preloaded as complete',
    );

    await container.read(onboardingCompleteProvider.notifier).markIncomplete();

    expect(
      container.read(onboardingCompleteProvider),
      isFalse,
      reason: 'state flips so the router redirects to the login flow',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(onboardingCompleteKey),
      isFalse,
      reason: 'the flag is persisted, not just held in memory',
    );
  });
}
