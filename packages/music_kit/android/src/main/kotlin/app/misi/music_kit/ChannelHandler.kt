package app.misi.music_kit

import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.annotation.Keep
import app.misi.music_kit.AuthActivityResultHandler.Companion.ERR_REQUEST_USER_TOKEN
import app.misi.music_kit.infrastructure.UserStorefrontRepository
import app.misi.music_kit.util.AppleDeveloperToken
import app.misi.music_kit.util.AppleMusicTokenProvider
import app.misi.music_kit.util.Constant.LOG_TAG
import com.apple.android.music.playback.controller.MediaPlayerController
import com.apple.android.music.playback.controller.MediaPlayerControllerFactory
import com.apple.android.music.playback.model.*
import com.apple.android.music.playback.queue.CatalogPlaybackQueueItemProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import kotlinx.coroutines.*


class ChannelHandler(
  private val applicationContext: Context,
  private val activityDispatcher: ActivityDispatcher
) : MethodCallHandler {
  companion object {
    const val METHOD_CHANNEL_NAME = "plugins.misi.app/music_kit"
    const val MUSIC_SUBSCRIPTION_EVENT_CHANNEL_NAME =
      "plugins.misi.app/music_kit/music_subscription"
    const val MUSIC_PLAYER_STATE_EVENT_CHANNEL_NAME = "plugins.misi.app/music_kit/player_state"
    const val MUSIC_PLAYER_QUEUE_EVENT_CHANNEL_NAME = "plugins.misi.app/music_kit/player_queue"

    const val PARAM_DEVELOPER_TOKEN_KEY = "developerToken"

    const val PREFERENCES_FILE_KEY = "plugins.misi.app_music_kit_preferences"
    const val PREFERENCES_KEY_MUSIC_USER_TOKEN = "musicUserToken"

    const val METADATA_KEY_TEAMID = "music_kit.teamId"
    const val METADATA_KEY_KEYID = "music_kit.keyId"
    const val METADATA_KEY_KEY = "music_kit.key"

    const val ERR_NOT_INITIALIZED = "ERR_NOT_INITIALIZED"
  }

  private var methodChannel: MethodChannel? = null
  private var playerStateEventChannel: EventChannel? = null
  private var playerQueueEventChannel: EventChannel? = null
  private var playerQueueStreamHandler: PlayerQueueStreamHandler? = null
  private var playerStateStreamHandler: PlayerStateStreamHandler? = null


  private lateinit var developerToken: String

  // Accessed from IO coroutine (fetchStorefrontAsync) and main thread (currentCountryCode).
  @Volatile
  private var storefrontId: String = "de"

  private var musicUserToken: String? = null
    set(value) {
      field = value
      persistUserToken(value)
      createPlayerControllerIfSatisfied(value)
      fetchStorefrontAsync(value)
    }

  // Accessed from main thread and Flutter method channel thread.
  @Volatile
  private var playerController: MediaPlayerController? = null

  // ExoPlayer-based DRM player for HLS streams.
  private var drmPlayer: AppleMusicDrmPlayer? = null

  private val coroutineScope = CoroutineScope(Dispatchers.IO)

  init {
    val appInfo = applicationContext.packageManager
      .getApplicationInfo(applicationContext.packageName, PackageManager.GET_META_DATA)
    val teamId = appInfo.metaData.getString(METADATA_KEY_TEAMID)!!
    val keyId = appInfo.metaData.getString(METADATA_KEY_KEYID)!!
    val key = appInfo.metaData.getString(METADATA_KEY_KEY)!!

    Log.d(LOG_TAG,"init teamId: $teamId keyId: $keyId")

    val apiToken = AppleDeveloperToken(key, keyId, teamId)
    developerToken = apiToken.toString()

    val token = applicationContext.getSharedPreferences(PREFERENCES_FILE_KEY, Context.MODE_PRIVATE)?.getString(
      PREFERENCES_KEY_MUSIC_USER_TOKEN, null)
    if (!token.isNullOrBlank()) {
      musicUserToken = token
    }

    Log.d(LOG_TAG, "init developerToken: ${developerToken.length} musicUserToken: ${musicUserToken?.length ?: 0}")
  }

  fun startListening(messenger: BinaryMessenger) {
    if (methodChannel != null
      || playerStateEventChannel != null
      || playerQueueEventChannel != null
      || playerStateStreamHandler != null
      || playerQueueStreamHandler != null
    ) {
      stopListening()
    }

    methodChannel = MethodChannel(messenger, METHOD_CHANNEL_NAME).apply {
      setMethodCallHandler(this@ChannelHandler)
    }

    playerStateStreamHandler = PlayerStateStreamHandler()
    playerStateEventChannel = EventChannel(messenger, MUSIC_PLAYER_STATE_EVENT_CHANNEL_NAME)
    playerStateEventChannel?.setStreamHandler(playerStateStreamHandler)

    playerQueueStreamHandler = PlayerQueueStreamHandler()
    playerQueueEventChannel = EventChannel(messenger, MUSIC_PLAYER_QUEUE_EVENT_CHANNEL_NAME)
    playerQueueEventChannel?.setStreamHandler(playerQueueStreamHandler)

    if (playerController != null) {
      playerStateStreamHandler!!.setPlayerController(playerController!!)
      playerQueueStreamHandler!!.setPlayerController(playerController!!)
    }
  }

  fun stopListening() {
    methodChannel?.setMethodCallHandler(null)
    methodChannel = null

    playerStateEventChannel?.setStreamHandler(null)
    playerStateEventChannel = null
    playerStateStreamHandler = null

    playerQueueEventChannel?.setStreamHandler(null)
    playerQueueEventChannel = null
    playerQueueStreamHandler = null

    playerController?.release()
    playerController = null
  }

  fun cleanUp() {
    coroutineScope.cancel()
    drmPlayer?.release()
    drmPlayer = null
  }

  // ── DRM HLS Player ──────────────────────────────────────────────────

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun playDrmStream(call: MethodCall, result: MethodChannel.Result) {
    val hlsUrl = call.argument<String>("hlsUrl")
    val licenseUrl = call.argument<String>("licenseUrl") ?: ""
    val devToken = call.argument<String>("developerToken") ?: developerToken
    val userToken = call.argument<String>("musicUserToken") ?: ""

    if (hlsUrl.isNullOrBlank() || userToken.isBlank()) {
      result.error("ERR_PLAY_DRM", "Missing hlsUrl or musicUserToken", null)
      return
    }

    if (drmPlayer == null) {
      drmPlayer = AppleMusicDrmPlayer(applicationContext)
    }

    val songId = call.argument<String>("songId") ?: ""

    drmPlayer?.play(
      hlsUrl = hlsUrl,
      licenseUrl = licenseUrl,
      developerToken = devToken,
      musicUserToken = userToken,
      songId = songId,
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

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerPosition(call: MethodCall, result: MethodChannel.Result) {
    result.success(drmPlayer?.currentPosition ?: 0L)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun drmPlayerDuration(call: MethodCall, result: MethodChannel.Result) {
    result.success(drmPlayer?.duration ?: 0L)
  }

  @Synchronized
  private fun createPlayerControllerIfSatisfied(musicUserToken: String?) {
    if (playerController == null && !musicUserToken.isNullOrBlank()) {
      Log.d(LOG_TAG, "Creating MediaPlayerController with devToken=${developerToken.length} chars, userToken=${musicUserToken.length} chars")
      playerController = MediaPlayerControllerFactory.createLocalController(
        applicationContext,
        AppleMusicTokenProvider(developerToken, musicUserToken)
      )
      playerStateStreamHandler?.setPlayerController(playerController!!)
      playerQueueStreamHandler?.setPlayerController(playerController!!)
      Log.d(LOG_TAG, "MediaPlayerController created successfully")
    }
  }

  private fun fetchStorefrontAsync(musicUserToken: String?) {
    if (musicUserToken.isNullOrBlank()) return
    coroutineScope.launch {
      try {
        val repo = UserStorefrontRepository()
        val response = repo.getStorefrontId(developerToken, musicUserToken)
        response.fold(
          { storefrontId = it; Log.d(LOG_TAG, "Storefront resolved: $it") },
          { Log.w(LOG_TAG, "Storefront fetch failed, using default: $storefrontId") },
        )
      } catch (e: Exception) {
        Log.w(LOG_TAG, "Storefront fetch error: ${e.message}")
      }
    }
  }

  private fun persistUserToken(musicUserToken: String?) {
    if (!musicUserToken.isNullOrBlank()) {
      val sharedPref = applicationContext.getSharedPreferences(
        PREFERENCES_FILE_KEY, Context.MODE_PRIVATE
      )
      with(sharedPref!!.edit()) {
        putString(PREFERENCES_KEY_MUSIC_USER_TOKEN, musicUserToken)
        apply()
      }
    }
  }



  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "authorizationStatus" -> authorizationStatus(call, result)
      "requestAuthorizationStatus" -> requestAuthorizationStatus(call, result)
      "requestDeveloperToken" -> requestDeveloperToken(call, result)
      "setMusicUserToken" -> setMusicUserToken(call, result)
      "requestUserToken" -> requestUserToken(call, result)
      "currentCountryCode" -> currentCountryCode(call, result)
      "setQueue" -> setQueue(call, result)
      "setQueueWithItems" -> setQueueWithItems(call, result)
      "play" -> play(call, result)
      "pause" -> pause(call, result)
      "stop" -> stop(call, result)
      "prepareToPlay" -> prepareToPlay(call, result)
      "skipToNextEntry" -> skipToNextEntry(call, result)
      "skipToPreviousEntry" -> skipToPreviousEntry(call, result)
      "restartCurrentEntry" -> restartCurrentEntry(call, result)
      "isPreparedToPlay" -> isPreparedToPlay(call, result)
      "playbackTime" -> playbackTime(call, result)
      "setPlaybackTime" -> setPlaybackTime(call, result)
      "currentItemDuration" -> currentItemDuration(call, result)
      "repeatMode" -> repeatMode(call, result)
      "setRepeatMode" -> setRepeatMode(call, result)
      "toggleRepeatMode" -> toggleRepeatMode(call, result)
      "shuffleMode" -> shuffleMode(call, result)
      "setShuffleMode" -> setShuffleMode(call, result)
      "toggleShuffleMode" -> toggleShuffleMode(call, result)
      "playDrmStream" -> playDrmStream(call, result)
      "drmPlayerPause" -> drmPlayerPause(call, result)
      "drmPlayerResume" -> drmPlayerResume(call, result)
      "drmPlayerStop" -> drmPlayerStop(call, result)
      "drmPlayerSeek" -> drmPlayerSeek(call, result)
      "drmPlayerPosition" -> drmPlayerPosition(call, result)
      "drmPlayerDuration" -> drmPlayerDuration(call, result)
      else -> result.notImplemented()
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun authorizationStatus(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(
        mapOf(
          "status" to 0,
          "musicUserToken" to musicUserToken,
        )
      ) //.authorized
    } else {
      result.success(mapOf("status" to 2)) // .notDetermined
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun requestAuthorizationStatus(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(
        mapOf(
          "status" to 0,
          "musicUserToken" to musicUserToken,
        )
      ) //.authorized
      return
    }

    if (!this::developerToken.isInitialized) {
      result.error(
        ERR_NOT_INITIALIZED,
        "developer token not initialized - make sure teamId, keyId and key are configured correctly in android",
        mapOf("developerToken" to developerToken, "musicUserToken" to musicUserToken)
      )
      return
    }

    val startScreenMessage = call.argument<String?>("startScreenMessage")
    activityDispatcher.showAuthActivity(developerToken, startScreenMessage) { token, error ->
      if (error != null) {
        result.error(ERR_REQUEST_USER_TOKEN, error.toString(), null)
      } else {
        musicUserToken = token
        result.success(
          mapOf(
            "status" to 0,
            "musicUserToken" to token,
          )
        )
      }
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun requestDeveloperToken(call: MethodCall, result: MethodChannel.Result) {
    result.success(developerToken)
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
    musicUserToken = token
    result.success(null)
  }

  @Keep
  fun requestUserToken(call: MethodCall, result: MethodChannel.Result) {
    if (!musicUserToken.isNullOrBlank()) {
      result.success(musicUserToken)
      return
    }

    val developerToken = call.argument<String>(PARAM_DEVELOPER_TOKEN_KEY)
    if (developerToken.isNullOrBlank()) {
      result.error(ERR_REQUEST_USER_TOKEN, null, null)
      return
    }

    val startScreenMessage = call.argument<String?>("startScreenMessage")

    this.developerToken = developerToken
    activityDispatcher.showAuthActivity(developerToken, startScreenMessage) { token, error ->
      if (error != null) {
        result.error(ERR_REQUEST_USER_TOKEN, error.toString(), null)
      } else {
        musicUserToken = token
        result.success(token)
      }
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun currentCountryCode(call: MethodCall, result: MethodChannel.Result) {
    // Returns the resolved storefront or "de" default. Never blocks.
    result.success(storefrontId)
  }


  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun isPreparedToPlay(call: MethodCall, result: MethodChannel.Result) {
    result.success(playerController != null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun playbackTime(call: MethodCall, result: MethodChannel.Result) {
    val positionMs = playerController?.currentPosition ?: 0L
    result.success(positionMs / 1000.0)
  }

  @Keep
  fun setPlaybackTime(call: MethodCall, result: MethodChannel.Result) {
    val seconds = call.arguments as? Double ?: 0.0
    if (seconds < 0 || !seconds.isFinite()) {
      result.error("INVALID_ARGUMENT", "Seek position must be >= 0 and finite", null)
      return
    }
    try {
      playerController?.seekToPosition((seconds * 1000).toLong())
      result.success(null)
    } catch (e: Exception) {
      Log.e(LOG_TAG, "seekToPosition failed: ${e.message}")
      result.error("ERR_SEEK", e.message, null)
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun currentItemDuration(call: MethodCall, result: MethodChannel.Result) {
    // Use the official getDuration() API instead of tracking via listener.
    val durationMs = playerController?.duration ?: 0L
    result.success(durationMs / 1000.0)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun musicPlayerState(call: MethodCall, result: MethodChannel.Result) {
    // Native PlaybackState is 1-based (STOPPED=1, PLAYING=2, PAUSED=3).
    // Dart MusicPlayerPlaybackStatus enum is 0-based. Subtract 1.
    val nativeState = playerController?.playbackState ?: PlaybackState.STOPPED
    val dartStatus = (nativeState - 1).coerceIn(0, 5)
    val state = mapOf<String, Any>(
      "playbackStatus" to dartStatus,
      "playbackRate" to ((playerController?.playbackRate ?: 1.0).toString().toDouble()),
      "repeatMode" to (playerController?.repeatMode ?: PlaybackRepeatMode.REPEAT_MODE_OFF),
      "shuffleMode" to (playerController?.shuffleMode ?: PlaybackShuffleMode.SHUFFLE_MODE_OFF),
    )
    result.success(state)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun pause(call: MethodCall, result: MethodChannel.Result) {
    playerController?.pause()
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun play(call: MethodCall, result: MethodChannel.Result) {
    Log.d(LOG_TAG, "play: state=${playerController?.playbackState}")
    playerController?.play()
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun prepareToPlay(call: MethodCall, result: MethodChannel.Result) {
    result.notImplemented()
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun restartCurrentEntry(call: MethodCall, result: MethodChannel.Result) {
    result.notImplemented()
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun skipToNextEntry(call: MethodCall, result: MethodChannel.Result) {
    if (playerController?.canSkipToNextItem() == true) {
      playerController?.skipToNextItem()
      result.success(null)
    } else {
      result.error("ERR_SKIP_TO_NEXT", null, null)
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun skipToPreviousEntry(call: MethodCall, result: MethodChannel.Result) {
    if (playerController?.canSkipToPreviousItem() == true) {
      playerController?.skipToPreviousItem()
      result.success(null)
    } else {
      result.error("ERR_SKIP_TO_PREVIOUS", null, null)
    }
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun stop(call: MethodCall, result: MethodChannel.Result) {
    playerController?.stop()
    result.success(null)
  }

  @Keep
  fun setQueue(call: MethodCall, result: MethodChannel.Result) {
    val itemType = call.argument<String>("type")
    val itemObject = call.argument<Map<String, Any>>("item")
    val autoplay = call.argument<Boolean>("autoplay") ?: true
    val queueProviderBuilder = CatalogPlaybackQueueItemProvider.Builder()
    val containerType: Int = when (itemType) {
      "albums" -> MediaContainerType.ALBUM
      "playlists" -> MediaContainerType.PLAYLIST
      else -> MediaContainerType.NONE
    }
    val id = itemObject?.get("id") as String
    Log.d(LOG_TAG, "setQueue: type=$itemType id=$id autoplay=$autoplay")
    queueProviderBuilder.containers(containerType, id)
    // prepare() is fire-and-forget: the SDK provides no completion callback.
    // Errors surface later via onPlaybackError listener.
    playerController?.prepare(queueProviderBuilder.build(), autoplay)
    result.success(null)
  }

  @Keep
  fun setQueueWithItems(call: MethodCall, result: MethodChannel.Result) {
    val itemType = call.argument<String>("type")
    val itemObjects = call.argument<List<Map<String, Any>>>("items")
    val startingAt = call.argument<Int>("startingAt")
    val queueProviderBuilder = CatalogPlaybackQueueItemProvider.Builder()
    val mediaItemType = when (itemType) {
      "songs", "tracks" -> MediaItemType.SONG
      else -> MediaItemType.UNKNOWN
    }
    val ids = itemObjects!!.map {
      it["id"] as String
    }.toTypedArray()
    queueProviderBuilder.items(mediaItemType, *ids)
    if (startingAt != null) {
      queueProviderBuilder.startItemIndex(startingAt)
    }
    playerController?.prepare(queueProviderBuilder.build(), true)
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun repeatMode(call: MethodCall, result: MethodChannel.Result) {
    val repeatMode: Int = playerController?.repeatMode ?: PlaybackRepeatMode.REPEAT_MODE_OFF
    result.success(repeatMode)
  }

  @Keep
  fun setRepeatMode(call: MethodCall, result: MethodChannel.Result) {
    if (playerController?.canSetRepeatMode() == true) {
      val mode = call.arguments as Int
      playerController?.repeatMode = mode
    }
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun toggleRepeatMode(call: MethodCall, result: MethodChannel.Result) {
    var repeatMode: Int = playerController?.repeatMode ?: PlaybackRepeatMode.REPEAT_MODE_OFF
    if (playerController?.canSetRepeatMode() == true) {
      repeatMode = (repeatMode + 2) % 3
      playerController?.repeatMode = repeatMode
    }
    result.success(repeatMode)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun shuffleMode(call: MethodCall, result: MethodChannel.Result) {
    val shuffleMode: Int = playerController?.shuffleMode ?: PlaybackShuffleMode.SHUFFLE_MODE_OFF
    result.success(shuffleMode)
  }

  @Keep
  fun setShuffleMode(call: MethodCall, result: MethodChannel.Result) {
    if (playerController?.canSetShuffleMode() == true) {
      val mode = call.arguments as Int
      playerController?.shuffleMode = mode
    }
    result.success(null)
  }

  @Keep
  @Suppress("unused", "UNUSED_PARAMETER")
  fun toggleShuffleMode(call: MethodCall, result: MethodChannel.Result) {
    var shuffleMode: Int = playerController?.shuffleMode ?: PlaybackShuffleMode.SHUFFLE_MODE_OFF
    if (playerController?.canSetShuffleMode() == true) {
      shuffleMode = when (shuffleMode) {
        PlaybackShuffleMode.SHUFFLE_MODE_OFF -> PlaybackShuffleMode.SHUFFLE_MODE_SONGS
        else -> PlaybackShuffleMode.SHUFFLE_MODE_OFF
      }
      playerController?.shuffleMode = shuffleMode
    }
    result.success(shuffleMode)
  }
}
