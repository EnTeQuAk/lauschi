package app.misi.music_kit

import android.content.Context
import android.util.Log
import androidx.annotation.Keep
import app.misi.music_kit.AuthActivityResultHandler.Companion.ERR_REQUEST_USER_TOKEN
import app.misi.music_kit.util.Constant.LOG_TAG
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/// Handles Flutter method channel calls for the music_kit plugin.
///
/// Auth: user token (web auth flow). The app fetches the developer token
/// from its server and passes it in, so no MusicKit key ships in the app.
/// Playback: DRM ExoPlayer via AppleMusicDrmPlayer (HLS + Widevine).
class ChannelHandler(
  private val applicationContext: Context,
  private val activityDispatcher: ActivityDispatcher,
) : MethodCallHandler {
  companion object {
    const val METHOD_CHANNEL_NAME = "plugins.misi.app/music_kit"
    const val DRM_PLAYER_STATE_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/drm_player_state"

    const val PARAM_DEVELOPER_TOKEN_KEY = "developerToken"

    const val ERR_NO_DEVELOPER_TOKEN = "ERR_NO_DEVELOPER_TOKEN"
  }

  private var methodChannel: MethodChannel? = null

  // DRM player state push via EventChannel.
  private var drmStateEventChannel: EventChannel? = null
  private var drmStateStreamHandler: DrmPlayerStateStreamHandler? = null

  // ExoPlayer-based DRM player for HLS streams.
  private var drmPlayer: AppleMusicDrmPlayer? = null

  // Set from Dart via setMusicUserToken() on session restore. Only stored
  // in FlutterSecureStorage on the Dart side.
  private var musicUserToken: String? = null

  fun startListening(messenger: BinaryMessenger) {
    if (methodChannel != null) stopListening()

    methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME).apply {
      setMethodCallHandler(this@ChannelHandler)
    }

    drmStateStreamHandler = DrmPlayerStateStreamHandler()
    drmStateEventChannel = EventChannel(messenger, DRM_PLAYER_STATE_EVENT_CHANNEL_NAME)
    drmStateEventChannel?.setStreamHandler(drmStateStreamHandler)

    drmPlayer?.listener = drmStateStreamHandler
  }

  fun stopListening() {
    methodChannel?.setMethodCallHandler(null)
    methodChannel = null

    drmStateEventChannel?.setStreamHandler(null)
    drmStateEventChannel = null
    drmStateStreamHandler = null
  }

  fun cleanUp() {
    drmPlayer?.release()
    drmPlayer = null
  }

  // ── Method dispatch ─────────────────────────────────────────────────

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // Auth
      "authorizationStatus" -> authorizationStatus(call, result)
      "requestAuthorizationStatus" -> requestAuthorizationStatus(call, result)
      "requestDeveloperToken" -> requestDeveloperToken(call, result)
      "setMusicUserToken" -> setMusicUserToken(call, result)
      "requestUserToken" -> requestUserToken(call, result)
      "currentCountryCode" -> currentCountryCode(call, result)

      // DRM playback
      "playDrmStream" -> playDrmStream(call, result)
      "drmPlayerPause" -> drmPlayerPause(call, result)
      "drmPlayerResume" -> drmPlayerResume(call, result)
      "drmPlayerStop" -> drmPlayerStop(call, result)
      "drmPlayerSeek" -> drmPlayerSeek(call, result)

      else -> result.notImplemented()
    }
  }

  // ── Auth ─────────────────────────────────────────────────────────────

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun authorizationStatus(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(mapOf("status" to 0, "musicUserToken" to musicUserToken))
    } else {
      result.success(mapOf("status" to 2)) // notDetermined
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun requestAuthorizationStatus(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(mapOf("status" to 0, "musicUserToken" to musicUserToken))
      return
    }

    // The native sign-in needs a developer token, and this call carries
    // none. Sign in through requestUserToken() instead.
    result.error(
      ERR_NO_DEVELOPER_TOKEN,
      "No developer token, call requestUserToken() with one",
      null,
    )
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun requestDeveloperToken(call: MethodCall, result: MethodChannel.Result) {
    // The app holds no MusicKit key on Android. It fetches the developer
    // token from its server (AppleMusicDeveloperToken on the Dart side).
    result.error(ERR_NO_DEVELOPER_TOKEN, "Android has no developer token to give", null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun setMusicUserToken(call: MethodCall, result: MethodChannel.Result) {
    val token = call.argument<String>("token")
    if (token.isNullOrBlank()) {
      result.error("ERR_SET_TOKEN", "Token is empty", null)
      return
    }
    Log.d(LOG_TAG, "setMusicUserToken: ${token.length} chars")
    setToken(token)
    // Pre-warm TLS connections to Apple's servers in the background.
    // First TLS handshake takes 20-30s on some devices. Called on
    // session restore (app start) and on app resume (after idle/background).
    AppleMusicDrmCallback.prewarmConnections()
    result.success(null)
  }

  @Keep
  fun requestUserToken(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(musicUserToken)
      return
    }

    val devToken = call.argument<String>(PARAM_DEVELOPER_TOKEN_KEY) ?: ""
    if (devToken.isBlank()) {
      result.error(ERR_REQUEST_USER_TOKEN, "No developer token", null)
      return
    }

    val startScreenMessage = call.argument<String?>("startScreenMessage")
    activityDispatcher.showAuthActivity(devToken, startScreenMessage) { token, error ->
      if (error != null) {
        result.error(ERR_REQUEST_USER_TOKEN, error.toString(), null)
      } else {
        setToken(token)
        result.success(token)
      }
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun currentCountryCode(call: MethodCall, result: MethodChannel.Result) {
    // Default to "de" (DACH market). The web auth callback provides the
    // actual storefront, which is used on the Dart side.
    result.success("de")
  }

  // ── DRM Playback ────────────────────────────────────────────────────

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun playDrmStream(call: MethodCall, result: MethodChannel.Result) {
    val hlsUrl = call.argument<String>("hlsUrl")
    val licenseUrl = call.argument<String>("licenseUrl") ?: ""
    val devToken = call.argument<String>(PARAM_DEVELOPER_TOKEN_KEY) ?: ""
    val userToken = call.argument<String>("musicUserToken") ?: ""

    if (hlsUrl.isNullOrBlank() || devToken.isBlank() || userToken.isBlank()) {
      result.error("ERR_PLAY_DRM", "Missing hlsUrl, developerToken or musicUserToken", null)
      return
    }

    if (drmPlayer == null) {
      drmPlayer = AppleMusicDrmPlayer(applicationContext).also {
        it.listener = drmStateStreamHandler
      }
    }

    val songId = call.argument<String>("songId") ?: ""
    val startPositionMs = call.argument<Number>("startPositionMs")?.toLong() ?: 0L

    drmPlayer?.play(
      hlsUrl = hlsUrl,
      licenseUrl = licenseUrl,
      developerToken = devToken,
      musicUserToken = userToken,
      songId = songId,
      startPositionMs = startPositionMs,
    )
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerPause(call: MethodCall, result: MethodChannel.Result) {
    drmPlayer?.pause()
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerResume(call: MethodCall, result: MethodChannel.Result) {
    drmPlayer?.resume()
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerStop(call: MethodCall, result: MethodChannel.Result) {
    drmPlayer?.stop()
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerSeek(call: MethodCall, result: MethodChannel.Result) {
    val positionMs = call.argument<Number>("positionMs")?.toLong() ?: 0L
    drmPlayer?.seekTo(positionMs)
    result.success(null)
  }

  // ── Internal ────────────────────────────────────────────────────────

  private fun setToken(token: String?) {
    musicUserToken = token
  }
}
