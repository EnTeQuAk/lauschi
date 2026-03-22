package app.misi.music_kit

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.FrameworkMediaDrm
import androidx.media3.exoplayer.hls.HlsMediaSource
import app.misi.music_kit.util.Constant.LOG_TAG

/**
 * Plays Apple Music HLS streams with Widevine DRM via ExoPlayer.
 *
 * Apple's HLS playlists use METHOD=ISO-23001-7 for CENC encryption,
 * which Media3's HLS parser doesn't recognize. We work around this
 * by using a custom DataSource that rewrites the method tag in the
 * playlist response before ExoPlayer parses it.
 */
class AppleMusicDrmPlayer(private val context: Context) {

    private var exoPlayer: ExoPlayer? = null
    private var playerListener: Player.Listener? = null
    var listener: Listener? = null

    interface Listener {
        fun onStateChanged(isPlaying: Boolean, position: Long, duration: Long)
        fun onError(message: String, errorCode: Int = 0)
        fun onTrackChanged(index: Int)
        fun onTrackEnded()
    }

    fun play(
        hlsUrl: String,
        licenseUrl: String,
        developerToken: String,
        musicUserToken: String,
        songId: String = "",
        startPositionMs: Long = 0
    ) {
        release()

        Log.d(LOG_TAG, "DrmPlayer: play hlsUrl=${hlsUrl.take(80)}...")

        // Auth headers for both stream fetching and license requests.
        val headers = mapOf(
            "Authorization" to "Bearer $developerToken",
            "Media-User-Token" to musicUserToken,
            "Origin" to "https://music.apple.com",
            "Referer" to "https://music.apple.com/",
            "User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        )

        // Share the OkHttpClient with the DRM callback so TLS sessions
        // are reused across all Apple Music HTTP requests. This means
        // pre-warming the callback's client also warms the HLS client.
        val httpDataSourceFactory = OkHttpDataSource.Factory(AppleMusicDrmCallback.httpClient)
            .setDefaultRequestProperties(headers)

        // Thread-safe holder for the key URI extracted from the HLS playlist.
        // The rewrite DataSource sets this when it parses the playlist;
        // the DRM callback reads it when sending the license request.
        val keyUriHolder = java.util.concurrent.atomic.AtomicReference("")

        val rewritingDataSourceFactory = DataSource.Factory {
            HlsMethodRewriteDataSource(httpDataSourceFactory.createDataSource(), keyUriHolder)
        }

        // Custom DRM callback that wraps Widevine challenges in Apple's
        // expected JSON format.
        val drmCallback = AppleMusicDrmCallback(
            licenseUrl = licenseUrl,
            headers = headers,
            songId = songId,
            keyUriProvider = { keyUriHolder.get() },
        )
        val drmSessionManager = DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            .build(drmCallback)

        // HLS media source with the rewriting data source and DRM session.
        val hlsMediaSourceFactory = HlsMediaSource.Factory(rewritingDataSourceFactory)
            .setDrmSessionManagerProvider { drmSessionManager }

        val mediaItem = MediaItem.fromUri(Uri.parse(hlsUrl))

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()

        val player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(hlsMediaSourceFactory)
            .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
            .build()
        Log.d(LOG_TAG, "DrmPlayer: Widevine DRM configured, licenseUrl=${licenseUrl.take(60)}")

        // No standalone MediaSession. audio_service already owns one via
        // its foreground service. Creating a second session confuses media
        // routing (Bluetooth, car displays, lock screen). The ExoPlayer
        // runs in the same process as audio_service's foreground service,
        // which satisfies AudioHardening on release builds.

        val newListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val pos = player.currentPosition
                val dur = player.duration.coerceAtLeast(0)
                val playing = player.isPlaying
                listener?.onStateChanged(playing, pos, dur)
                if (playbackState == Player.STATE_ENDED) {
                    Log.d(LOG_TAG, "DrmPlayer: track ended")
                    listener?.onTrackEnded()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                listener?.onStateChanged(isPlaying, player.currentPosition, player.duration.coerceAtLeast(0))
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                listener?.onTrackChanged(player.currentMediaItemIndex)
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e(LOG_TAG, "DrmPlayer: error ${error.errorCode}: ${error.message}", error)
                listener?.onError("${error.errorCodeName}: ${error.message}", error.errorCode)
            }
        }
        playerListener = newListener
        player.addListener(newListener)

        // Use the HLS factory (with rewriting DataSource) to create the source
        // from the MediaItem (which carries the DRM config).
        val mediaSource = hlsMediaSourceFactory.createMediaSource(mediaItem)
        player.setMediaSource(mediaSource)
        player.prepare()

        if (startPositionMs > 0) {
            player.seekTo(startPositionMs)
        }

        player.play()
        exoPlayer = player
        Log.d(LOG_TAG, "DrmPlayer: started")
    }

    fun pause() { exoPlayer?.pause() }
    fun resume() { exoPlayer?.play() }
    fun stop() { exoPlayer?.stop() }
    fun seekTo(positionMs: Long) { exoPlayer?.seekTo(positionMs) }
    val currentPosition: Long get() = exoPlayer?.currentPosition ?: 0
    val duration: Long get() = exoPlayer?.duration?.coerceAtLeast(0) ?: 0

    fun release() {
        // Remove listeners BEFORE release to prevent the final STATE_IDLE
        // callback from pushing the old position to Dart. Without this,
        // the old track's position leaks into the new track's state.
        exoPlayer?.removeListener(playerListener)
        exoPlayer?.release()
        exoPlayer = null
    }
}
