package app.misi.music_kit

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.annotation.Keep
import app.misi.music_kit.AuthActivityResultHandler.Companion.ERR_REQUEST_USER_TOKEN
import app.misi.music_kit.util.AppleDeveloperToken
import app.misi.music_kit.util.Constant.LOG_TAG
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler

/// Handles Flutter method channel calls for the music_kit plugin.
///
/// Auth: developer token (JWT from .p8 key), user token (web auth flow).
/// Playback: DRM ExoPlayer via AppleMusicDrmPlayer (HLS + Widevine).
class ChannelHandler(
  private val applicationContext: Context,
  private val activityDispatcher: ActivityDispatcher,
) : MethodCallHandler {
  companion object {
    const val METHOD_CHANNEL_NAME = "plugins.misi.app/music_kit"
    const val DRM_PLAYER_STATE_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/drm_player_state"

    // Legacy event channel names kept for platform interface compatibility.
    // The channels are registered but unused (no stream handlers attached).
    const val MUSIC_PLAYER_STATE_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/player_state"
    const val MUSIC_PLAYER_QUEUE_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/player_queue"
    const val MUSIC_SUBSCRIPTION_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/music_subscription"

    const val PARAM_DEVELOPER_TOKEN_KEY = "developerToken"

    const val PREFERENCES_FILE_KEY = "plugins.misi.app_music_kit_preferences"
    const val PREFERENCES_KEY_MUSIC_USER_TOKEN = "musicUserToken"

    const val METADATA_KEY_TEAMID = "music_kit.teamId"
    const val METADATA_KEY_KEYID = "music_kit.keyId"
    const val METADATA_KEY_KEY = "music_kit.key"

    const val ERR_NOT_INITIALIZED = "ERR_NOT_INITIALIZED"
  }

  private var methodChannel: MethodChannel? = null

  // DRM player state push via EventChannel.
  private var drmStateEventChannel: EventChannel? = null
  private var drmStateStreamHandler: DrmPlayerStateStreamHandler? = null

  // ExoPlayer-based DRM player for HLS streams.
  private var drmPlayer: AppleMusicDrmPlayer? = null

  // Credentials read from AndroidManifest metadata at init. Used to
  // generate developer tokens on demand (not cached, regenerated each call).
  private var teamId: String = ""
  private var keyId: String = ""
  private var privateKey: String = ""
  private var musicUserToken: String? = null

  init {
    val appInfo = applicationContext.packageManager
      .getApplicationInfo(applicationContext.packageName, PackageManager.GET_META_DATA)
    teamId = appInfo.metaData.getString(METADATA_KEY_TEAMID) ?: ""
    keyId = appInfo.metaData.getString(METADATA_KEY_KEYID) ?: ""
    privateKey = appInfo.metaData.getString(METADATA_KEY_KEY) ?: ""

    Log.d(
      LOG_TAG,
      "init teamId: $teamId keyId: $keyId key=${
        if (privateKey.isNotBlank()) "${privateKey.length} chars" else "MISSING"
      }",
    )

    if (privateKey.isBlank() || teamId.isBlank() || keyId.isBlank()) {
      Log.w(LOG_TAG, "MusicKit credentials missing, Apple Music will be unavailable")
    }

    // Restore persisted user token (from previous web auth session).
    val token = applicationContext.getSharedPreferences(
      PREFERENCES_FILE_KEY, Context.MODE_PRIVATE,
    )?.getString(PREFERENCES_KEY_MUSIC_USER_TOKEN, null)
    if (!token.isNullOrBlank()) {
      musicUserToken = token
    }

    Log.d(
      LOG_TAG,
      "init musicUserToken: ${musicUserToken?.length ?: 0}",
    )
  }

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

    if (privateKey.isBlank()) {
      result.error(
        ERR_NOT_INITIALIZED,
        "Developer token not initialized",
        null,
      )
      return
    }

    val startScreenMessage = call.argument<String?>("startScreenMessage")
    activityDispatcher.showAuthActivity(generateDeveloperToken(), startScreenMessage) { token, error ->
      if (error != null) {
        result.error(ERR_REQUEST_USER_TOKEN, error.toString(), null)
      } else {
        setToken(token)
        result.success(mapOf("status" to 0, "musicUserToken" to token))
      }
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun requestDeveloperToken(call: MethodCall, result: MethodChannel.Result) {
    result.success(generateDeveloperToken())
  }

  /// Generate a fresh developer token JWT. Called on every
  /// requestDeveloperToken() so the token never expires during
  /// long-running sessions (a kids tablet left on for months).
  /// ECDSA signing is fast (~1ms), no reason to cache.
  private fun generateDeveloperToken(): String {
    if (privateKey.isBlank() || teamId.isBlank() || keyId.isBlank()) {
      return ""
    }
    return try {
      AppleDeveloperToken(privateKey, keyId, teamId).toString()
    } catch (e: Exception) {
      Log.e(LOG_TAG, "Failed to generate developer token", e)
      ""
    }
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
    // First TLS handshake takes 20-50s on some devices; by warming up
    // now, the connections are ready when the user taps play.
    AppleMusicDrmCallback.prewarmConnections()
    result.success(null)
  }

  @Keep
  fun requestUserToken(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(musicUserToken)
      return
    }

    val devToken = call.argument<String>(PARAM_DEVELOPER_TOKEN_KEY)
        ?: generateDeveloperToken()
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
    val devToken = call.argument<String>("developerToken")
      ?: generateDeveloperToken()
    val userToken = call.argument<String>("musicUserToken") ?: ""

    if (hlsUrl.isNullOrBlank() || userToken.isBlank()) {
      result.error("ERR_PLAY_DRM", "Missing hlsUrl or musicUserToken", null)
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
    persistUserToken(token)
  }

  private fun persistUserToken(token: String?) {
    if (!token.isNullOrBlank()) {
      applicationContext.getSharedPreferences(
        PREFERENCES_FILE_KEY, Context.MODE_PRIVATE,
      ).edit().putString(PREFERENCES_KEY_MUSIC_USER_TOKEN, token).apply()
    }
  }
}
