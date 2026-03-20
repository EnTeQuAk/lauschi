package app.misi.music_kit

import android.util.Log
import app.misi.music_kit.util.Constant.LOG_TAG
import com.apple.android.music.playback.controller.MediaPlayerController
import com.apple.android.music.playback.model.*
import io.flutter.plugin.common.EventChannel

class PlayerStateStreamHandler() :
  EventChannel.StreamHandler {
  private var eventSink: EventChannel.EventSink? = null

  private var playerController: MediaPlayerController? = null

  fun setPlayerController(controller: MediaPlayerController) {
    playerController?.removeListener(playerControllerListener)
    controller.addListener(playerControllerListener)
    playerController = controller

    updatePlaybackState(controller)
  }


  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  private val playerControllerListener = object : MediaPlayerController.Listener {
    override fun onPlayerStateRestored(p0: MediaPlayerController) {
      Log.d(LOG_TAG, "State Handler onPlayerStateRestored()")
    }

    override fun onPlaybackStateChanged(
      p0: MediaPlayerController,
      previousState: Int,
      currentState: Int
    ) {
      Log.d(
        LOG_TAG,
        "State Handler onPlaybackStateChanged() prevState: $previousState currentState: $currentState"
      )
      updatePlaybackState(p0)
    }

    override fun onPlaybackStateUpdated(p0: MediaPlayerController) {
      Log.d(LOG_TAG, "State Handler onPlaybackStateUpdated()")
    }

    override fun onBufferingStateChanged(p0: MediaPlayerController, p1: Boolean) {
      Log.d(LOG_TAG, "State Handler onBufferingStateChanged() buffering: $p1")
      updatePlaybackState(p0)
    }

    override fun onCurrentItemChanged(
      p0: MediaPlayerController,
      previousItem: PlayerQueueItem?,
      currentItem: PlayerQueueItem?
    ) {
      Log.d(
        LOG_TAG,
        "State Handler onCurrentItemChanged() prevItem: ${previousItem?.playbackQueueId} currentItem: ${currentItem?.playbackQueueId}"
      )
      updatePlaybackState(p0)
    }

    override fun onItemEnded(p0: MediaPlayerController, p1: PlayerQueueItem, p2: Long) {
      Log.d(LOG_TAG, "State Handler onItemEnded() queueItem: ${p1.playbackQueueId} endPosition: $p2")
    }

    override fun onMetadataUpdated(p0: MediaPlayerController, p1: PlayerQueueItem) {
      Log.d(LOG_TAG, "State Handler onMetadataUpdated() queueItem: ${p1.playbackQueueId}")
    }

    override fun onPlaybackQueueChanged(
      p0: MediaPlayerController,
      p1: MutableList<PlayerQueueItem>
    ) {
      Log.d(LOG_TAG, "State Handler onPlaybackQueueChanged() numOfQueueItems: ${p1.size}")
    }

    override fun onPlaybackQueueItemsAdded(p0: MediaPlayerController, p1: Int, p2: Int, p3: Int) {
      Log.d(
        LOG_TAG,
        "State Handler onPlaybackQueueItemsAdded() insertionType: $p1 containerType: $p2 itemType: $p3"
      )
    }

    override fun onPlaybackError(p0: MediaPlayerController, p1: MediaPlayerException) {
      Log.d(LOG_TAG, "State Handler TEST onPlaybackError() error(${p1.errorCode}): ${p1.message}", p1)
    }

    override fun onPlaybackRepeatModeChanged(p0: MediaPlayerController, p1: Int) {
      Log.d(LOG_TAG, "State Handler onPlaybackRepeatModeChanged() repeatMode: $p1")
    }

    override fun onPlaybackShuffleModeChanged(p0: MediaPlayerController, p1: Int) {
      Log.d(LOG_TAG, "State Handler onPlaybackShuffleModeChanged() shuffleMode: $p1")
    }
  }

  private fun updatePlaybackState(controller: MediaPlayerController) {
    val state = mapOf<String, Any>(
      "playbackStatus" to controller.playbackState,
      "playbackRate" to controller.playbackRate,
      "repeatMode" to controller.repeatMode,
      "shuffleMode" to controller.shuffleMode,
    )
    eventSink?.success(state)
  }

}
