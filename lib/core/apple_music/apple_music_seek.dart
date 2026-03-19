import 'package:flutter/services.dart';
import 'package:lauschi/core/log.dart';

const _tag = 'AppleMusicSeek';
const _channel = MethodChannel('app.lauschi.lauschi/apple_music_seek');

/// Seek to a position in the current Apple Music playback.
///
/// The music_kit Flutter plugin (v1.3.0) doesn't expose setPlaybackTime.
/// This uses a direct platform channel as a workaround.
///
/// Platform behavior:
/// - **Android**: Needs access to MusicKit's MediaPlayerController (not yet
///   wired up, see #231). Currently returns NOT_IMPLEMENTED.
/// - **iOS**: Native MusicKit has `player.playbackTime = seconds` (not yet
///   connected via platform channel).
///
/// WORKAROUND: See https://github.com/misiio/flutter_music_kit/pull/3
Future<void> seekAppleMusic(double seconds) async {
  if (seconds < 0 || !seconds.isFinite) {
    Log.warn(_tag, 'Invalid seek position: $seconds');
    return;
  }
  try {
    await _channel.invokeMethod<void>('seekTo', {'seconds': seconds});
    Log.debug(_tag, 'Seeked to ${seconds.toStringAsFixed(1)}s');
  } on PlatformException catch (e) {
    Log.warn(_tag, 'Seek failed', data: {'error': e.message ?? 'unknown'});
  } on MissingPluginException {
    Log.warn(_tag, 'Seek not available on this platform');
  }
}
