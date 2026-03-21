package app.misi.music_kit

import android.content.Context
import android.net.Uri
import android.support.v4.media.session.MediaSessionCompat
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.drm.DefaultDrmSessionManager
import androidx.media3.exoplayer.drm.HttpMediaDrmCallback
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
    private var mediaSession: MediaSessionCompat? = null
    var listener: Listener? = null

    interface Listener {
        fun onStateChanged(isPlaying: Boolean, position: Long, duration: Long)
        fun onError(message: String)
        fun onTrackChanged(index: Int)
    }

    fun play(
        hlsUrl: String,
        licenseUrl: String,
        developerToken: String,
        musicUserToken: String,
        startIndex: Int = 0,
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

        // DataSource that adds auth headers and rewrites ISO-23001-7 in HLS playlists.
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(headers)

        val rewritingDataSourceFactory = DataSource.Factory {
            HlsMethodRewriteDataSource(httpDataSourceFactory.createDataSource())
        }

        // Widevine DRM session with Apple's license server.
        val drmCallback = HttpMediaDrmCallback(licenseUrl, httpDataSourceFactory)
        // Apple's license server needs the same auth headers.
        for ((key, value) in headers) {
            drmCallback.setKeyRequestProperty(key, value)
        }

        val drmSessionManager = DefaultDrmSessionManager.Builder()
            .setUuidAndExoMediaDrmProvider(C.WIDEVINE_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
            .build(drmCallback)

        // HLS media source with DRM and the rewriting data source.
        val hlsMediaSourceFactory = HlsMediaSource.Factory(rewritingDataSourceFactory)
            .setDrmSessionManagerProvider { drmSessionManager }

        // Build MediaItem with DRM configuration so ExoPlayer knows to
        // use Widevine for this content.
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(hlsUrl))
            .setDrmConfiguration(
                MediaItem.DrmConfiguration.Builder(C.WIDEVINE_UUID)
                    .setLicenseUri(licenseUrl)
                    .setLicenseRequestHeaders(headers)
                    .build()
            )
            .build()
        val mediaSource = hlsMediaSourceFactory.createMediaSource(mediaItem)

        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()

        val player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(hlsMediaSourceFactory)
            .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ true)
            .build()

        // Create a MediaSession and associate it with the ExoPlayer.
        // This tells Android the player is a legitimate foreground media
        // source, preventing AudioHardening from muting the output.
        // The audio_service package has its own MediaSession for the
        // notification, but Android allows multiple sessions. Ours just
        // needs to be active so the audio system trusts us.
        val session = MediaSessionCompat(context, "AppleMusicDrmPlayer").apply {
            isActive = true
        }
        mediaSession = session
        Log.d(LOG_TAG, "DrmPlayer: MediaSession created and active")

        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                val pos = player.currentPosition
                val dur = player.duration.coerceAtLeast(0)
                val playing = player.isPlaying
                Log.d(LOG_TAG, "DrmPlayer: state=$playbackState playing=$playing pos=$pos dur=$dur")
                listener?.onStateChanged(playing, pos, dur)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                listener?.onStateChanged(isPlaying, player.currentPosition, player.duration.coerceAtLeast(0))
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                listener?.onTrackChanged(player.currentMediaItemIndex)
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e(LOG_TAG, "DrmPlayer: error ${error.errorCode}: ${error.message}", error)
                listener?.onError("${error.errorCodeName}: ${error.message}")
            }
        })

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
    fun seekToNext() { exoPlayer?.seekToNextMediaItem() }
    fun seekToPrevious() { exoPlayer?.seekToPreviousMediaItem() }
    val currentPosition: Long get() = exoPlayer?.currentPosition ?: 0
    val duration: Long get() = exoPlayer?.duration?.coerceAtLeast(0) ?: 0
    val isPlaying: Boolean get() = exoPlayer?.isPlaying ?: false
    val currentIndex: Int get() = exoPlayer?.currentMediaItemIndex ?: 0

    fun release() {
        exoPlayer?.release()
        exoPlayer = null
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
    }
}
