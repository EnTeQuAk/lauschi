package app.misi.music_kit

import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import app.misi.music_kit.util.Constant.LOG_TAG
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Wraps another DataSource and rewrites Apple's HLS encryption tags
 * so ExoPlayer's HLS parser can handle them.
 *
 * Apple uses `METHOD=ISO-23001-7` in their HLS playlists for CENC encryption.
 * ExoPlayer only recognizes `SAMPLE-AES-CTR`. Additionally, Apple omits the
 * `KEYFORMAT` attribute that ExoPlayer needs to identify the key as Widevine
 * DRM. Without KEYFORMAT, ExoPlayer treats encrypted segments as identity-keyed
 * and never creates a DRM session, leaving MediaCodec without a crypto context.
 *
 * Only HLS playlists are rewritten (detected by `#EXTM3U` + `ISO-23001-7`).
 * Audio segments pass through without buffering.
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

        // Peek at the first bytes to check if this is an HLS playlist.
        // Playlists start with "#EXTM3U" (7 bytes). Audio segments are
        // binary data that won't match. Only buffer the full response
        // if it's a playlist that needs rewriting.
        val peekBuf = ByteArray(PEEK_SIZE)
        val peekRead = upstream.read(peekBuf, 0, PEEK_SIZE)
        if (peekRead <= 0) {
            upstream.close()
            bufferedData = ByteArray(0)
            return 0
        }

        val peekStr = String(peekBuf, 0, peekRead, Charsets.UTF_8)
        if (!peekStr.trimStart().startsWith(EXTM3U_HEADER)) {
            // Not a playlist. Return peek bytes + remaining upstream reads.
            // Don't buffer the entire segment (300-400KB) in memory.
            bufferedData = null
            isPlaylist = false
            // Store peek bytes so read() can serve them first.
            _peekData = peekBuf.copyOf(peekRead)
            _peekOffset = 0
            _upstreamOpen = true
            return length
        }

        // It's a playlist. Read the rest and check if rewriting is needed.
        val baos = ByteArrayOutputStream(peekRead + 4096)
        baos.write(peekBuf, 0, peekRead)
        val readBuf = ByteArray(READ_BUFFER_SIZE)
        while (true) {
            val read = upstream.read(readBuf, 0, READ_BUFFER_SIZE)
            if (read == C.RESULT_END_OF_INPUT) break
            baos.write(readBuf, 0, read)
        }
        upstream.close()

        val raw = baos.toByteArray()
        val text = String(raw, Charsets.UTF_8)

        if (text.contains("ISO-23001-7")) {
            isPlaylist = true
            Log.d(LOG_TAG, "HlsRewrite: patching ISO-23001-7 → SAMPLE-AES-CTR + KEYFORMAT")

            // Extract the key URI for the license request.
            // Apple's EXT-X-KEY URI contains a raw key ID (16 bytes), not a
            // full PSSH box. We build a proper Widevine PSSH box so ExoPlayer
            // generates a valid license challenge. Without this, Apple's
            // license server returns errorCode 100000 / status -1021.
            val uriMatch = Regex("""URI="data:;base64,([^"]+)"""").find(text)
            val rawKeyB64 = uriMatch?.groupValues?.get(1) ?: ""
            keyUriHolder.set("data:;base64,$rawKeyB64")

            val rawKeyBytes = Base64.decode(rawKeyB64, Base64.DEFAULT)
            val psshBox = buildWidevinePssh(rawKeyBytes)
            val psshB64 = Base64.encodeToString(psshBox, Base64.NO_WRAP)

            val rewritten = text.replace(
                Regex("""#EXT-X-KEY:METHOD=ISO-23001-7,URI="[^"]+""""),
                """#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed",KEYFORMATVERSIONS="1",URI="data:text/plain;base64,$psshB64""""
            )
            bufferedData = rewritten.toByteArray(Charsets.UTF_8)
        } else {
            // Playlist but doesn't need rewriting.
            bufferedData = raw
        }

        return bufferedData!!.size.toLong()
    }

    // For non-playlist (audio segment) pass-through.
    private var _peekData: ByteArray? = null
    private var _peekOffset = 0
    private var _upstreamOpen = false

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        // Buffered path: playlist data served from memory.
        if (bufferedData != null) {
            val data = bufferedData!!
            if (readOffset >= data.size) return C.RESULT_END_OF_INPUT
            val bytesToRead = minOf(length, data.size - readOffset)
            System.arraycopy(data, readOffset, buffer, offset, bytesToRead)
            readOffset += bytesToRead
            return bytesToRead
        }

        // Pass-through path: serve peek bytes first, then upstream.
        val peek = _peekData
        if (peek != null && _peekOffset < peek.size) {
            val bytesToRead = minOf(length, peek.size - _peekOffset)
            System.arraycopy(peek, _peekOffset, buffer, offset, bytesToRead)
            _peekOffset += bytesToRead
            if (_peekOffset >= peek.size) _peekData = null
            return bytesToRead
        }

        // Peek exhausted, read from upstream.
        return if (_upstreamOpen) {
            upstream.read(buffer, offset, length)
        } else {
            C.RESULT_END_OF_INPUT
        }
    }

    override fun getUri(): Uri? = currentUri

    override fun close() {
        bufferedData = null
        _peekData = null
        _upstreamOpen = false
        readOffset = 0
        // Close upstream if it was left open (pass-through path).
        try { upstream.close() } catch (_: Exception) {}
    }

    companion object {
        private const val EXTM3U_HEADER = "#EXTM3U"
        private const val PEEK_SIZE = 32
        private const val READ_BUFFER_SIZE = 8192

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
         * The PSSH data is a serialized WidevinePsshData protobuf
         * (see https://github.com/nichochar/nichochar.com for format reference):
         *   field 1 (algorithm): tag=0x08, varint value 1 (AESCTR)
         *   field 2 (key_id): tag=0x12, length-delimited, raw key ID bytes
         *
         * PSSH box format (version 0):
         *   4 bytes: box size (big-endian)
         *   4 bytes: 'pssh' type
         *   4 bytes: version 0 + flags 0
         *   16 bytes: Widevine system ID
         *   4 bytes: data size
         *   N bytes: WidevinePsshData protobuf
         */
        fun buildWidevinePssh(keyId: ByteArray): ByteArray {
            require(keyId.isNotEmpty() && keyId.size <= 127) {
                "Invalid key ID size: ${keyId.size} (expected 1-127, typically 16)"
            }
            val protobuf = ByteArray(2 + 2 + keyId.size)
            protobuf[0] = 0x08  // field 1 tag (varint)
            protobuf[1] = 0x01  // AESCTR = 1
            protobuf[2] = 0x12  // field 2 tag (length-delimited)
            protobuf[3] = keyId.size.toByte()
            System.arraycopy(keyId, 0, protobuf, 4, keyId.size)

            val boxSize = 4 + 4 + 4 + 16 + 4 + protobuf.size
            val buf = ByteBuffer.allocate(boxSize).order(ByteOrder.BIG_ENDIAN)
            buf.putInt(boxSize)
            buf.put("pssh".toByteArray())
            buf.putInt(0)
            buf.put(WIDEVINE_SYSTEM_ID)
            buf.putInt(protobuf.size)
            buf.put(protobuf)
            return buf.array()
        }
    }
}
