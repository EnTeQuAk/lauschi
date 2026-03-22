package app.misi.music_kit

import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import app.misi.music_kit.util.Constant.LOG_TAG
import java.nio.ByteBuffer
import java.nio.ByteOrder

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
    private val upstream: DataSource,
    private val keyUriHolder: java.util.concurrent.atomic.AtomicReference<String>,
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

            // Extract the key URI and build a proper Widevine PSSH box.
            // Apple's EXT-X-KEY URI contains a raw key ID (16 bytes), not a
            // full PSSH box. ExoPlayer needs a valid PSSH to generate a proper
            // Widevine license challenge. Without it, the challenge is malformed
            // and Apple's license server returns errorCode 100000 / status -1021.
            val uriMatch = Regex("""URI="data:;base64,([^"]+)"""").find(text)
            val rawKeyB64 = uriMatch?.groupValues?.get(1) ?: ""
            val originalUri = "data:;base64,$rawKeyB64"
            keyUriHolder.set(originalUri)

            // Build a valid Widevine PSSH box from the raw key ID.
            val rawKeyBytes = Base64.decode(rawKeyB64, Base64.DEFAULT)
            val psshBox = buildWidevinePssh(rawKeyBytes)
            val psshB64 = Base64.encodeToString(psshBox, Base64.NO_WRAP)
            Log.d(LOG_TAG, "HlsRewrite: rawKey=${rawKeyBytes.size} bytes → PSSH=${psshBox.size} bytes")

            // Rewrite the EXT-X-KEY tag with the proper PSSH box URI.
            val rewritten = text.replace(
                Regex("""#EXT-X-KEY:METHOD=ISO-23001-7,URI="[^"]+""""),
                """#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",KEYFORMATVERSIONS="1",URI="data:text/plain;base64,$psshB64""""
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

    companion object {
        // Widevine system ID: edef8ba9-79d6-4ace-a3c8-27dcd51d21ed
        private val WIDEVINE_SYSTEM_ID = byteArrayOf(
            0xed.toByte(), 0xef.toByte(), 0x8b.toByte(), 0xa9.toByte(),
            0x79.toByte(), 0xd6.toByte(), 0x4a.toByte(), 0xce.toByte(),
            0xa3.toByte(), 0xc8.toByte(), 0x27.toByte(), 0xdc.toByte(),
            0xd5.toByte(), 0x1d.toByte(), 0x21.toByte(), 0xed.toByte()
        )

        /**
         * Build a valid PSSH box for Widevine from raw key ID bytes.
         *
         * PSSH box format (version 0):
         *   4 bytes: box size (big-endian)
         *   4 bytes: 'pssh' box type
         *   1 byte:  version (0)
         *   3 bytes: flags (0)
         *   16 bytes: system ID (Widevine UUID)
         *   4 bytes: data size (big-endian)
         *   N bytes: data (the raw key ID or Widevine init data)
         */
        fun buildWidevinePssh(keyId: ByteArray): ByteArray {
            val dataSize = keyId.size
            val boxSize = 4 + 4 + 4 + 16 + 4 + dataSize  // 32 + keyId.size
            val buf = ByteBuffer.allocate(boxSize).order(ByteOrder.BIG_ENDIAN)
            buf.putInt(boxSize)                    // box size
            buf.put("pssh".toByteArray())          // box type
            buf.putInt(0)                          // version 0 + flags 0
            buf.put(WIDEVINE_SYSTEM_ID)            // system ID
            buf.putInt(dataSize)                   // data size
            buf.put(keyId)                         // data (raw key ID)
            return buf.array()
        }
    }
}
