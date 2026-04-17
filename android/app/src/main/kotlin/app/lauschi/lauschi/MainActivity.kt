package app.lauschi.lauschi

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SEEK_CHANNEL = "app.lauschi.lauschi/apple_music_seek"
        private const val LOG_TAG = "MainActivity"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge-to-edge is handled automatically by Flutter on Android 15+
        // https://developer.android.com/about/versions/15/behavior-changes-15#edge-to-edge
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SEEK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "seekTo" -> {
                        val seconds = call.argument<Double>("seconds") ?: 0.0
                        // WORKAROUND: The music_kit plugin doesn't expose the
                        // MusicKit MediaPlayback controller. This channel is
                        // ready for when we get access to it (#231).
                        Log.d(LOG_TAG, "seekTo($seconds) requested but not implemented")
                        result.error(
                            "NOT_IMPLEMENTED",
                            "Seek requires access to MusicKit MediaPlayback instance. See #231.",
                            seconds
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
