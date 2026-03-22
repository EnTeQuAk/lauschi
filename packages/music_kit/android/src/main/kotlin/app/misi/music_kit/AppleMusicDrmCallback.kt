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
        val httpClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()

        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()

        /**
         * Pre-warm TLS connections to Apple's servers.
         * First TLS handshake can take 20-50s on some devices.
         * Call during session restore so connections are ready when user plays.
         */
        fun prewarmConnections() {
            // Warm each host on its own thread in parallel.
            // Sequential warming took ~50s (20s + 30s). Parallel should
            // complete in ~30s (max of the two).
            val hosts = listOf(
                "https://aod-ssl.itunes.apple.com/",
                "https://play.itunes.apple.com/",
            )
            for (host in hosts) {
                Thread {
                    try {
                        val t0 = System.currentTimeMillis()
                        val req = Request.Builder().url(host).head().build()
                        httpClient.newCall(req).execute().close()
                        Log.d(LOG_TAG, "DrmCallback: pre-warmed TLS to $host in ${System.currentTimeMillis() - t0}ms")
                    } catch (e: Exception) {
                        Log.d(LOG_TAG, "DrmCallback: pre-warm to $host failed (non-fatal)")
                    }
                }.start()
            }
        }
    }

    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest
    ): ByteArray {
        val t0 = System.currentTimeMillis()
        val url = request.defaultUrl + "&signedRequest=" + String(request.data)
        Log.d(LOG_TAG, "DrmCallback: provisioning started")
        val req = Request.Builder().url(url).post(
            ByteArray(0).toRequestBody(null)
        ).build()
        val response = httpClient.newCall(req).execute()
        val result = response.body?.bytes() ?: ByteArray(0)
        response.close()
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
