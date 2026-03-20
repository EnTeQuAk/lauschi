package app.misi.music_kit.util

import android.util.Base64
import io.jsonwebtoken.Jwts
import java.security.KeyFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date

class AppleDeveloperToken(private val key: String, private val keyId: String, private val teamId: String) {

    private companion object {
        fun generateToken(privateKey: String, keyId: String, teamId: String): String {
            val appleKey = KeyFactory.getInstance("EC")
                .generatePrivate(PKCS8EncodedKeySpec(Base64.decode(privateKey, Base64.DEFAULT)))
            val now = Date()

            val jwt = Jwts.builder().apply {
                header().add("alg", "ES256").add("kid", keyId)
                claim("iss", teamId)
                issuedAt(now)
                expiration(Date(now.time + 150L * 24 * 1000 * 60 * 60)) // exp = 150 days, can be up to 6 month
            }.signWith(appleKey, Jwts.SIG.ES256).compact()

            return jwt
        }
    }

    private val token: String = Companion.generateToken(key, keyId, teamId);

    override fun toString(): String {
        return token
    }
}