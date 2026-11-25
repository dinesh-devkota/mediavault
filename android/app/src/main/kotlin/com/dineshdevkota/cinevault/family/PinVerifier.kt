package com.dineshdevkota.cinevault.family

import java.security.MessageDigest
import java.security.SecureRandom
import java.security.NoSuchAlgorithmException
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.PKCS5S2ParametersGenerator
import org.bouncycastle.crypto.params.KeyParameter
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
            return try {
                val factory = try { SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256") }
                catch (_: NoSuchAlgorithmException) { return derivePortable(pin, salt, rounds) }
                factory.generateSecret(spec).encoded
            }
            finally { spec.clearPassword() }
        }

        /** Identical algorithm, iteration count and bytes on pre-26 Android; never changes stored PINs. */
        internal fun derivePortable(pin: String, salt: ByteArray, rounds: Int = ROUNDS): ByteArray {
            require(valid(pin) && salt.size == 16 && rounds == ROUNDS)
            val password = pin.toByteArray(Charsets.UTF_8)
            return try {
                PKCS5S2ParametersGenerator(SHA256Digest()).run {
                    init(password, salt, rounds)
                    (generateDerivedParameters(256) as KeyParameter).key
                }
            } finally { password.fill(0) }
        }
    }
}
