package com.dineshdevkota.cinevault.family

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import kotlinx.serialization.Serializable

/** Only salted, stretched verifiers are persisted, inside Keystore-encrypted storage. */
@Serializable
data class PinVerifier(val salt: String, val hash: String, val rounds: Int = ROUNDS) {
    fun matches(pin: String): Boolean {
        if (!valid(pin) || rounds != ROUNDS) return false
        return MessageDigest.isEqual(Base64.getDecoder().decode(hash), derive(pin, Base64.getDecoder().decode(salt), rounds))
    }

    companion object {
        const val ROUNDS = 210_000
        fun valid(pin: String): Boolean = pin.length == 6 && pin.all { it in '0'..'9' }
        fun create(pin: String): PinVerifier {
            require(valid(pin)) { "Use exactly six digits." }
            val salt = ByteArray(16).also { SecureRandom().nextBytes(it) }
            return PinVerifier(Base64.getEncoder().encodeToString(salt), Base64.getEncoder().encodeToString(derive(pin, salt, ROUNDS)))
        }
        private fun derive(pin: String, salt: ByteArray, rounds: Int): ByteArray {
            val spec = PBEKeySpec(pin.toCharArray(), salt, rounds, 256)
            return try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded }
            finally { spec.clearPassword() }
        }
    }
}
