package app.misi.music_kit

import android.util.Log
import app.misi.music_kit.util.Constant.LOG_TAG
import io.flutter.plugin.common.EventChannel

/**
 * Forwards DRM player state changes from [AppleMusicDrmPlayer.Listener]
 * to Flutter via an [EventChannel].
 *
 * Replaces the 500ms position polling in AppleMusicPlayer.dart with
 * push-based state updates. Same pattern as PlayerStateStreamHandler
 * (used for the legacy MediaPlayerController).
 */
class DrmPlayerStateStreamHandler : EventChannel.StreamHandler, AppleMusicDrmPlayer.Listener {

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onStateChanged(isPlaying: Boolean, position: Long, duration: Long) {
        eventSink?.success(
            mapOf(
                "type" to "state",
                "isPlaying" to isPlaying,
                "positionMs" to position,
                "durationMs" to duration,
            )
        )
    }

    override fun onError(message: String) {
        Log.e(LOG_TAG, "DrmPlayer error forwarded to Dart: $message")
        eventSink?.success(
            mapOf(
                "type" to "error",
                "message" to message,
            )
        )
    }

    override fun onTrackChanged(index: Int) {
        eventSink?.success(
            mapOf(
                "type" to "trackChanged",
                "index" to index,
            )
        )
    }

    override fun onTrackEnded() {
        eventSink?.success(
            mapOf("type" to "trackEnded")
        )
    }
}
