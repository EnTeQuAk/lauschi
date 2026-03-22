package app.misi.music_kit

import android.util.Base64
import android.util.Log
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import app.misi.music_kit.util.Constant.LOG_TAG
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * Custom DRM callback for Apple Music's Widevine license server.
 *
 * Apple's license endpoint expects a JSON request body with the Widevine
 * challenge base64-encoded, plus metadata fields. The response is also JSON
 * with the license in a `license` field.
 */
class AppleMusicDrmCallback(
    private val licenseUrl: String,
    private val headers: Map<String, String>,
    private val songId: String = "",
    private val keyUriProvider: () -> String = { "" },
) : MediaDrmCallback {

    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest
    ): ByteArray {
        val t0 = System.currentTimeMillis()
        Log.d(LOG_TAG, "DrmCallback: provisioning started, url=${request.defaultUrl}")
        val url = request.defaultUrl + "&signedRequest=" + String(request.data)
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        val result = Util.toByteArray(connection.inputStream)
        Log.d(LOG_TAG, "DrmCallback: provisioning done in ${System.currentTimeMillis() - t0}ms")
        return result
    }

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest
    ): ByteArray {
        val t0 = System.currentTimeMillis()
        Log.d(LOG_TAG, "DrmCallback: license request starting")

        val challengeB64 = Base64.encodeToString(request.data, Base64.NO_WRAP)
        val resolvedKeyUri = keyUriProvider()
        val jsonBody = JSONObject().apply {
            put("challenge", challengeB64)
            put("key-system", "com.widevine.alpha")
            put("uri", resolvedKeyUri)
            put("adamId", songId)
            put("isLibrary", false)
            put("user-initiated", true)
        }
        val bodyBytes = jsonBody.toString().toByteArray()
        Log.d(LOG_TAG, "DrmCallback: challenge built in ${System.currentTimeMillis() - t0}ms, body=${bodyBytes.size} bytes")

        val t1 = System.currentTimeMillis()
        val connection = URL(licenseUrl).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.connectTimeout = 15_000
        connection.readTimeout = 120_000
        connection.setRequestProperty("Content-Type", "application/json")
        for ((key, value) in headers) {
            connection.setRequestProperty(key, value)
        }
        Log.d(LOG_TAG, "DrmCallback: connection opened in ${System.currentTimeMillis() - t1}ms")

        val t2 = System.currentTimeMillis()
        connection.outputStream.use { it.write(bodyBytes) }
        Log.d(LOG_TAG, "DrmCallback: request body sent in ${System.currentTimeMillis() - t2}ms")

        val t3 = System.currentTimeMillis()
        val responseCode = connection.responseCode
        Log.d(LOG_TAG, "DrmCallback: response code $responseCode received in ${System.currentTimeMillis() - t3}ms")

        if (responseCode != 200) {
            val errorBody = try {
                connection.errorStream?.bufferedReader()?.readText() ?: ""
            } catch (e: Exception) { "" }
            Log.e(LOG_TAG, "DrmCallback: license server returned $responseCode: ${errorBody.take(200)}")
            throw RuntimeException("License request failed with HTTP $responseCode")
        }

        val t4 = System.currentTimeMillis()
        val responseBody = connection.inputStream.bufferedReader().readText()
        Log.d(LOG_TAG, "DrmCallback: response body read in ${System.currentTimeMillis() - t4}ms, total=${System.currentTimeMillis() - t0}ms")

        val responseJson = JSONObject(responseBody)
        val licenseB64 = when {
            responseJson.has("license") -> responseJson.getString("license")
            responseJson.has("License") -> responseJson.getString("License")
            responseJson.has("ckc") -> responseJson.getString("ckc")
            else -> {
                val keys = responseJson.keys().asSequence().toList()
                Log.e(LOG_TAG, "DrmCallback: no license in response. Keys: $keys")
                throw RuntimeException("No license field in response. Keys: $keys")
            }
        }

        Log.d(LOG_TAG, "DrmCallback: license acquired, total=${System.currentTimeMillis() - t0}ms")
        return Base64.decode(licenseB64, Base64.DEFAULT)
    }
}
