package app.misi.music_kit

import android.util.Base64
import android.util.Log
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.drm.ExoMediaDrm
import androidx.media3.exoplayer.drm.MediaDrmCallback
import app.misi.music_kit.util.Constant.LOG_TAG
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Custom DRM callback for Apple Music's Widevine license server.
 *
 * Apple's license endpoint expects a JSON request body with the Widevine
 * challenge base64-encoded, plus metadata fields. The response is also JSON
 * with the license in a `license` field.
 *
 * Uses OkHttp instead of HttpURLConnection for reliable connection
 * handling (DNS, TLS, keep-alive). HttpURLConnection on Android can
 * hang for 60+ seconds on stale TLS connections.
 */
class AppleMusicDrmCallback(
    private val licenseUrl: String,
    private val headers: Map<String, String>,
    private val songId: String = "",
    private val keyUriProvider: () -> String = { "" },
) : MediaDrmCallback {

    companion object {
        private val httpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()

        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }

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
        val bodyBytes = jsonBody.toString()

        Log.d(LOG_TAG, "DrmCallback: sending license request (${bodyBytes.length} bytes)")

        val requestBuilder = Request.Builder()
            .url(licenseUrl)
            .post(bodyBytes.toRequestBody(JSON_MEDIA_TYPE))

        for ((key, value) in headers) {
            requestBuilder.addHeader(key, value)
        }

        val t1 = System.currentTimeMillis()
        val response = httpClient.newCall(requestBuilder.build()).execute()
        val responseTime = System.currentTimeMillis() - t1

        Log.d(LOG_TAG, "DrmCallback: HTTP ${response.code} in ${responseTime}ms")

        if (response.code != 200) {
            val errorBody = response.body?.string()?.take(200) ?: ""
            Log.e(LOG_TAG, "DrmCallback: license server error: $errorBody")
            response.close()
            throw RuntimeException("License request failed with HTTP ${response.code}")
        }

        val responseBody = response.body?.string() ?: ""
        response.close()
        Log.d(LOG_TAG, "DrmCallback: license acquired, total=${System.currentTimeMillis() - t0}ms")

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

        return Base64.decode(licenseB64, Base64.DEFAULT)
    }
}
