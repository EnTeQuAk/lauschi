package app.misi.music_kit

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import app.misi.music_kit.util.Constant.LOG_TAG

/**
 * Wraps another DataSource and rewrites Apple's HLS encryption method tag
 * so ExoPlayer's HLS parser can handle it.
 *
 * Apple uses `METHOD=ISO-23001-7` in their HLS playlists for CENC encryption.
 * ExoPlayer's parser only recognizes `SAMPLE-AES-CTR` for the same encryption
 * scheme. This DataSource intercepts .m3u8 responses and rewrites the tag.
 */
class HlsMethodRewriteDataSource(
    private val upstream: DataSource
) : DataSource {

    private var isPlaylist = false
    private var bufferedData: ByteArray? = null
    private var readOffset = 0

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val uri = dataSpec.uri.toString()
        isPlaylist = uri.endsWith(".m3u8") || uri.contains("m3u8")

        if (!isPlaylist) {
            return upstream.open(dataSpec)
        }

        // For playlists: read the entire response, rewrite, buffer it.
        val length = upstream.open(dataSpec)
        val bytes = mutableListOf<Byte>()
        val buf = ByteArray(8192)
        while (true) {
            val read = upstream.read(buf, 0, buf.size)
            if (read == C.RESULT_END_OF_INPUT) break
            for (i in 0 until read) bytes.add(buf[i])
        }
        upstream.close()

        var content = String(bytes.toByteArray(), Charsets.UTF_8)
        if (content.contains("ISO-23001-7")) {
            Log.d(LOG_TAG, "HlsRewrite: patching ISO-23001-7 → SAMPLE-AES-CTR")
            content = content.replace("ISO-23001-7", "SAMPLE-AES-CTR")
        }

        bufferedData = content.toByteArray(Charsets.UTF_8)
        readOffset = 0
        return bufferedData!!.size.toLong()
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (!isPlaylist) {
            return upstream.read(buffer, offset, length)
        }

        val data = bufferedData ?: return C.RESULT_END_OF_INPUT
        if (readOffset >= data.size) return C.RESULT_END_OF_INPUT

        val bytesToRead = minOf(length, data.size - readOffset)
        System.arraycopy(data, readOffset, buffer, offset, bytesToRead)
        readOffset += bytesToRead
        return bytesToRead
    }

    override fun getUri(): Uri? = upstream.uri

    override fun close() {
        if (!isPlaylist) {
            upstream.close()
        }
        bufferedData = null
        readOffset = 0
    }
}
