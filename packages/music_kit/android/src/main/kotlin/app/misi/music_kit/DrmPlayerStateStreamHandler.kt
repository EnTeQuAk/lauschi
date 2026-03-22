package app.misi.music_kit

import android.util.Log
import app.misi.music_kit.util.Constant.LOG_TAG
import io.flutter.plugin.common.EventChannel

/**
 * Forwards DRM ExoPlayer state changes to Flutter via [EventChannel].
 *
 * Events are maps sent via `eventSink.success()` (not `error()`) with
 * a `type` discriminator. The Dart side parses the type in
 * `AppleMusicPlayer._onDrmStateEvent`. Using `success()` for all event
 * types (including errors) is the standard Flutter EventChannel pattern
 * for typed payloads.
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

    override fun onError(message: String, errorCode: Int) {
        Log.e(LOG_TAG, "DrmPlayer error forwarded to Dart: $message (code=$errorCode)")
        eventSink?.success(
            mapOf(
                "type" to "error",
                "message" to message,
                "errorCode" to errorCode,
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
