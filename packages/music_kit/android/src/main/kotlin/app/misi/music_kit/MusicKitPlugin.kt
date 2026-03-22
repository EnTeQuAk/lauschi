package app.misi.music_kit

import android.util.Log
import androidx.annotation.NonNull
import app.misi.music_kit.util.Constant.LOG_TAG

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/** MusicKitPlugin */
class MusicKitPlugin : FlutterPlugin, ActivityAware {
  private lateinit var activityDispatcher: ActivityDispatcher
  private lateinit var channelHandler: ChannelHandler

  companion object {
    init {
      // The mediaplayback AAR (Apple's native SDK) was removed because it
      // had a 5-10 min startup delay. Playback now uses ExoPlayer + Widevine.
      // The native libraries (appleMusicSDK, c++_shared) are no longer needed.
      // If musickitauth still needs native libs, load them non-fatally.
      try {
        System.loadLibrary("c++_shared")
      } catch (e: UnsatisfiedLinkError) {
        Log.w(LOG_TAG, "c++_shared not available (expected after mediaplayback removal)")
      }
    }
  }

  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    activityDispatcher = ActivityDispatcher(flutterPluginBinding.applicationContext)
    channelHandler = ChannelHandler(flutterPluginBinding.applicationContext, activityDispatcher)
    channelHandler.startListening(flutterPluginBinding.binaryMessenger)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    Log.d(LOG_TAG, "onAttachedToActivity")
    binding.addActivityResultListener(activityDispatcher)
    activityDispatcher.activity = binding.activity
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    Log.d(LOG_TAG, "onReattachedToActivityForConfigChanges")
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    Log.d(LOG_TAG, "onDetachedFromActivity")
    activityDispatcher.activity = null
  }

  override fun onDetachedFromActivityForConfigChanges() {
    Log.d(LOG_TAG, "onDetachedFromActivityForConfigChanges")
    onDetachedFromActivity()
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(LOG_TAG, "onDetachedFromEngine")
    channelHandler.stopListening()
    channelHandler.cleanUp()
  }
}

