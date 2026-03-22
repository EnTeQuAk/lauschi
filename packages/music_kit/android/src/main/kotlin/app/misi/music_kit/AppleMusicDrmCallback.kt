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
 * with the license in a `license` field. ExoPlayer's default
 * HttpMediaDrmCallback sends raw binary, which Apple rejects with HTTP 500.
 */
class AppleMusicDrmCallback(
    private val licenseUrl: String,
    private val headers: Map<String, String>,
    private val songId: String = "",
    private val keyUri: String = "",
) : MediaDrmCallback {

    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest
    ): ByteArray {
        // Widevine L3 provisioning (if needed). Standard HTTP POST.
        val url = request.defaultUrl + "&signedRequest=" + String(request.data)
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        return Util.toByteArray(connection.inputStream)
    }

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest
    ): ByteArray {
        Log.d(LOG_TAG, "DrmCallback: sending license request to $licenseUrl")

        // Wrap the Widevine challenge in Apple's expected JSON format.
        val challengeB64 = Base64.encodeToString(request.data, Base64.NO_WRAP)
        val jsonBody = JSONObject().apply {
            put("challenge", challengeB64)
            put("key-system", "com.widevine.alpha")
            put("uri", keyUri)
            put("adamId", songId)
            put("isLibrary", false)
            put("user-initiated", true)
        }

        val connection = URL(licenseUrl).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")

        // Add auth headers.
        for ((key, value) in headers) {
            connection.setRequestProperty(key, value)
        }

        // Send the JSON request.
        connection.outputStream.use { it.write(jsonBody.toString().toByteArray()) }

        val responseCode = connection.responseCode
        if (responseCode != 200) {
            val errorBody = try {
                connection.errorStream?.bufferedReader()?.readText() ?: ""
            } catch (e: Exception) { "" }
            Log.e(LOG_TAG, "DrmCallback: license server returned $responseCode: ${errorBody.take(200)}")
            throw RuntimeException("License request failed with HTTP $responseCode")
        }

        // Parse the JSON response and extract the base64 license.
        val responseBody = connection.inputStream.bufferedReader().readText()
        Log.d(LOG_TAG, "DrmCallback: response (${responseBody.length} chars): ${responseBody.take(300)}")

        val responseJson = JSONObject(responseBody)

        // Apple may return the license under different keys.
        val licenseB64 = when {
            responseJson.has("license") -> responseJson.getString("license")
            responseJson.has("License") -> responseJson.getString("License")
            responseJson.has("ckc") -> responseJson.getString("ckc")
            else -> {
                // Log all keys for debugging.
                val keys = responseJson.keys().asSequence().toList()
                Log.e(LOG_TAG, "DrmCallback: no license in response. Keys: $keys")
                throw RuntimeException("No license field in response. Keys: $keys")
            }
        }

        Log.d(LOG_TAG, "DrmCallback: license received (${licenseB64.length} chars)")
        return Base64.decode(licenseB64, Base64.DEFAULT)
    }
}
