import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/features/onboarding/screens/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('markIncomplete resets state and persists false', () async {
    SharedPreferences.setMockInitialValues({'onboarding_complete': true});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(onboardingCompleteProvider.notifier).checkAsync();
    expect(
      container.read(onboardingCompleteProvider),
      isTrue,
      reason: 'setup: onboarding starts complete',
    );

    await container.read(onboardingCompleteProvider.notifier).markIncomplete();

    expect(
      container.read(onboardingCompleteProvider),
      isFalse,
      reason: 'state flips so the router redirects to the login flow',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('onboarding_complete'),
      isFalse,
      reason: 'the flag is persisted, not just held in memory',
    );
  });
}
