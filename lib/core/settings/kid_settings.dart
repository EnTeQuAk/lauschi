import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'kid_settings.g.dart';

const _keyShowEpisodeTitles = 'kid.show_episode_titles';

/// Whether to show episode titles on kid-mode tiles (below episode number).
/// Default: false — only the episode number is shown.
@Riverpod(keepAlive: true)
class ShowEpisodeTitles extends _$ShowEpisodeTitles {
  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyShowEpisodeTitles) ?? false;
  }

  Future<void> toggle() async {
    final current = state.value ?? false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowEpisodeTitles, !current);
    state = AsyncData(!current);
  }
}
