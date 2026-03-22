package app.misi.music_kit

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import app.misi.music_kit.util.Constant.LOG_TAG

/**
 * Wraps another DataSource and rewrites Apple's HLS encryption tags
 * so ExoPlayer's HLS parser can handle them.
 *
 * Apple uses `METHOD=ISO-23001-7` in their HLS playlists for CENC encryption.
 * ExoPlayer only recognizes `SAMPLE-AES-CTR`. Additionally, Apple omits the
 * `KEYFORMAT` attribute that ExoPlayer needs to identify the key as Widevine
 * DRM (vs identity/AES-128 encryption). Without KEYFORMAT, ExoPlayer never
 * creates a DRM session, leaving MediaCodec without a crypto context.
 *
 * This DataSource intercepts playlist responses (detected by `#EXTM3U` header)
 * and rewrites both the METHOD and injects the KEYFORMAT attribute.
 */
class HlsMethodRewriteDataSource(
    private val upstream: DataSource
) : DataSource {

    private var isPlaylist = false
    private var bufferedData: ByteArray? = null
    private var readOffset = 0
    private var currentUri: Uri? = null

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        currentUri = dataSpec.uri
        isPlaylist = false
        bufferedData = null
        readOffset = 0

        val length = upstream.open(dataSpec)

        // Read the full response to check if it's a playlist.
        // HLS playlists are small (< 100KB). Audio segments are large.
        val bytes = mutableListOf<Byte>()
        val buf = ByteArray(8192)
        while (true) {
            val read = upstream.read(buf, 0, buf.size)
            if (read == C.RESULT_END_OF_INPUT) break
            for (i in 0 until read) bytes.add(buf[i])
        }
        upstream.close()

        val raw = bytes.toByteArray()
        val text = String(raw, Charsets.UTF_8)

        if (text.trimStart().startsWith("#EXTM3U") && text.contains("ISO-23001-7")) {
            isPlaylist = true
            Log.d(LOG_TAG, "HlsRewrite: patching ISO-23001-7 → SAMPLE-AES-CTR + KEYFORMAT")
            // Rewrite METHOD and inject KEYFORMAT so ExoPlayer identifies
            // the encryption as Widevine DRM and creates a proper DRM session.
            val rewritten = text.replace(
                "METHOD=ISO-23001-7",
                """METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",KEYFORMATVERSIONS="1""""
            )
            bufferedData = rewritten.toByteArray(Charsets.UTF_8)
        } else {
            // Not a playlist needing rewrite. Buffer as-is.
            bufferedData = raw
        }

        return bufferedData!!.size.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val data = bufferedData ?: return C.RESULT_END_OF_INPUT
        if (readOffset >= data.size) return C.RESULT_END_OF_INPUT

        val bytesToRead = minOf(length, data.size - readOffset)
        System.arraycopy(data, readOffset, buffer, offset, bytesToRead)
        readOffset += bytesToRead
        return bytesToRead
    }

    override fun getUri(): Uri? = currentUri

    override fun close() {
        bufferedData = null
        readOffset = 0
    }
}
