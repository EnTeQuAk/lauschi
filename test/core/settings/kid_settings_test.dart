import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lauschi/core/settings/kid_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build reads the persisted value and defaults to false', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(await container.read(showEpisodeTitlesProvider.future), isFalse);
  });

  test('set writes the given value to state and prefs', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(showEpisodeTitlesProvider.future);

    await container.read(showEpisodeTitlesProvider.notifier).set(value: true);
    expect(container.read(showEpisodeTitlesProvider).value, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('kid.show_episode_titles'), isTrue);

    await container.read(showEpisodeTitlesProvider.notifier).set(value: false);
    expect(container.read(showEpisodeTitlesProvider).value, isFalse);
  });
}
