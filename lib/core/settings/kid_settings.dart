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

  /// Set the flag directly. Driven by the settings switch, which already
  /// carries the desired value, so there's no read-then-flip: a still-loading
  /// state can't be misread as false, and rapid taps settle to the switch's
  /// final position instead of collapsing a double-toggle.
  Future<void> set({required bool value}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowEpisodeTitles, value);
    state = AsyncData(value);
  }
}
